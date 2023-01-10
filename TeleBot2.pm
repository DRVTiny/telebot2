#!/usr/bin/perl
# Async Telegram bot implementation using WWW::Telegram::BotAPI
# See also https://gist.github.com/Robertof/d9358b80d95850e2eb34
package TeleBot2;

# See https://docs.mojolicious.org/Mojo/UserAgent#inactivity_timeout
use constant MOJO_NO_INACT_TIMEOUT => 0; 

use constant {
    INACT_TIMEOUT	=> MOJO_NO_INACT_TIMEOUT,
    USER_AGENT_MAX_CONN =>  150,
    GET_UPD_TIMEOUT	=>  30,
    REDIS_DB_N		=>  10,
    DEFAULT_PASS_PHRASE => 'Perl is the best programming language in the world'
};

use utf8;
use 5.16.1;
use EV;
use AnyEvent;
use Mojo::Base -strict;
use WWW::Telegram::BotAPI;
use JSON::XS;
use Log::Dispatch;
use Data::Dumper;
use Scalar::Util 	qw(refaddr blessed);
#use List::Util		qw(first);
use Ref::Util 		qw(is_hashref is_coderef is_arrayref is_scalarref);
binmode $_, ':utf8' for *STDOUT, *STDERR;
use Redis;
my %aeh;

my %ext_pars=(
    'dont_manage_ev_loop'=>{
        'map' => 'no_loop'
    },
    'token'=>{
        'map' => 'token'
    },
    'bot_username' => undef,
    'redis_db_n' => undef,
    'logger' => undef,
    'passphrase' => undef
);

sub new {
    my ($class, %pars)=@_;
    my $slf = {'passphrase' => DEFAULT_PASS_PHRASE, 'do_after_init' => []};
    for ( grep defined $pars{$_}, keys %ext_pars ) {
        $slf->{
            (is_hashref($ext_pars{$_}) and $ext_pars{$_}{'map'}) 
                ? $ext_pars{$_}{'map'}
                : $_
        } = $pars{$_}
    } 

    my $redc = $slf->{'redc'} = Redis->new;
    $slf->{'logger'} ||= Log::Dispatch->new('outputs'=>[['Screen','min_level' => 'debug', 'newline' => 1, 'stderr' => 1]]);
    # Select Redis database we need to store our chan_id's
    $redc->select($slf->{'redis_db_n'} || REDIS_DB_N);
    
    $slf->{'token'} ||= 
        $slf->{'bot_username'} 
            ? $redc->hget('telebot-tokens', $slf->{'bot_username'}) 
            : undef
        or die 'You must provide token to be possible to control the TeleBot';
    
    my $teleBot = $slf->{'bot'} = WWW::Telegram::BotAPI->new(
        'token' => $slf->{'token'},
        'async' => 1
    );
    my $ua = $teleBot->agent;
    # Disable the inactivity timeout of Mojo::UserAgent
    $ua->inactivity_timeout (INACT_TIMEOUT);
    # Keep-alive max 150 connections at once
    $ua->max_connections(USER_AGENT_MAX_CONN);
    
    # If we have detected that "some_proxy" environment variables was set, tell our Mojo::UserAgent instance to use them
    $teleBot->agent->proxy->detect
        if grep defined $_, @ENV{map 'http'.$_.'_proxy', 's', ''};
    
    bless $slf, (ref $class || $class);
}

sub start {
    my $slf = shift;
    my $log = $slf->{'logger'};
    # Fetch bot information asynchronously
    $slf->{'bot'}->api_request('getMe', $slf->wrap_async(sub {
        my $me = shift;
        $slf->{'account'} = $me;
        $log->debug("Telegram bot << $me->{'first_name'} >> initialized and ready to fetch updates!");
        if (my %chans_by_id = eval { my %t=$slf->{'redc'}->hgetall('channels'); map { $_=>$t{$_} } grep /^-?\d+$/, keys %t }) {
            utf8::decode($_) for values %chans_by_id;
            $slf->{'chans'}{'by_id'}=\%chans_by_id;
            $slf->{'chans'}{'by_title'}={ map { $chans_by_id{$_} => $_ } keys %chans_by_id };
            $log->info( join("\n\t"=>'Loaded channels:', map join(' => #', each(%{$slf->{'chans'}{'by_title'}})), 1..scalar(keys %chans_by_id) ) );
        } else {
            $log->warn('No channels defined yet, waiting for updates to be possible to flood anywhere');
        }
        $slf->fetch_updates();
        $slf->on_init();
    }));
    unless ($slf->{'no_loop'}) {
        $SIG{'INT'}=sub { $log->warn('OOOOOOH, NO!! You interrupted me by Ctrl+C/Break pressing...'); Mojo::IOLoop->stop };
        Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
    }
}

sub stop {
    my $slf = shift;
    Mojo::IOLoop->stop
        if ! $slf->{'no_loop'} and Mojo::IOLoop->is_running;
}

sub logger {
    my ($slf,$logger)=@_;
    return unless ref($logger) and blessed($logger);
    for (qw(debug info warn error)) {
        return unless $logger->can($_)
    }
    $slf->{'logger'}=$logger;
}

sub __det_chat_title {
    my $chat = $_[0];
    my @try_this = 
        $chat->{'type'} eq 'private' 
            ? ('username', ['first_name', 'last_name']) 
            : ('title');
    my $chat_title;
    for my $fld ( @try_this ) { 
        $chat_title = is_arrayref($fld) 
                        ? join(' ' => map defined($chat->{$_}) && length($chat->{$_}) ? $chat->{$_} : (), @{$fld})
                        : ($chat->{$fld} // '');
        length($chat_title) and last
    }
    
    $chat_title
}

# Async update handling
sub fetch_updates {
    state $offset = 0;
    
    my $slf = shift;
    my $log = $slf->{'logger'};
    
    $slf->{'bot'}->getUpdates ({
        'timeout' 		=> GET_UPD_TIMEOUT,
        'allowed_updates' 	=> ['message'], # remove me in production if you need multiple update types
        $offset ? ('offset' => $offset) : ()
    } => $slf->wrap_async( sub {
        my $updates = shift;
        for my $update (@$updates) {
            $log->debug( '+++++++++++ Received update: '.JSON::XS->new->pretty->encode($update));
            $offset = $update->{'update_id'} + 1 if $update->{'update_id'} >= $offset;
            # Handle text messages. No checks are needed because of `allowed_updates`
            my $message = $update->{'message'};
            my $message_text = $message->{'text'} || '<nothing>';
            $log->debug(sprintf "> Incoming message from \@%s:\n>> %s", 
                                join(' '=> map defined($_) ? $_ : (), @{$message->{'from'}}{qw[first_name last_name]}),
                                $message_text);
            my $chat = $message->{'chat'};
            my $chat_id = $chat->{'id'};
            my $chat_title =  __det_chat_title( $chat );
            # For this example, we're just going to handle messages containing '/say something'
            given ($message_text) {
                when (/^<nothing>$/) {
                    $slf->{'bot'}->sendMessage ({
                        'chat_id' => $chat_id, 
                        'text' => $slf->{'chans'}{$chat_id}
                            ? sprintf('TeleBot %s is ready to send notificatons to your channel', $slf->{'account'}{'first_name'})
                            : 'You must /auth first to get any notifications from me'
                    }, sub {});
                }
                when (/^\/say(?:\s+(.*))?$/i) {
                    # For this example, we don't care about the result of sendMessage.
                    # JSON->new->pretty->encode
                    $slf->{'bot'}->sendMessage ({
                        'chat_id' => $chat_id,
                        'text'    => 
                               $1
                                ? 'Your chat dump: ' . Dumper($message->{'chat'}) 
                                : 'Oh, do you really have nothing to say?'
                    } => sub { $log->debug("> Replied to /say") })
                }
                when (/^\/auth\s+(.+)$/) {
                    if ($slf->{'passphrase'} eq $1) {
                        $slf->{'bot'}->sendMessage ({
                            'chat_id'=>$chat_id,
                            'text'=>$slf->{'chans'}{$chat_id}
                                ? do {
                                    $log->debug('Received auth request, but this channel is already authorized. Nothing to do');
                                    'I am already authorized to use this channel'
                                  }                            
                                : do {
                                    $log->info("New chat with chan_title=<< $chat_title >> was succesfully authorized, remember its chat_id=<< $chat_id >>");
                                    $slf->{'chans'}{'by_id'   }{$chat_id   } = $chat_title;
                                    $slf->{'chans'}{'by_title'}{$chat_title} = $chat_id;
                                    utf8::encode($chat_title);
                                    $slf->{'redc'}->hset('channels', $chat_id, $chat_title, sub {
                                        $log->debug(sprintf qq(=> OK, we have remembered that channel id of <<%s>> is %d\n), $chat_title, $chat_id)
                                    });
                                    'Now i am authorized to send messages to this channel subscribers. Thanks!'
                                  }
                        }, sub {});
                    } else {
                        $log->warn('User specified incorrect passphrase');
                        $slf->{'bot'}->sendMessage ({'chat_id'=>$chat_id,'text'=>'Passphrase is incorrect'},sub{});
                    }
                }
            }
        }
        # Run the request again using ourselves as the handler :-)
        $slf->fetch_updates();
    }));
}

sub on_init {
    my $slf = $_[0];
    $slf->initialized = 1;
    while ( @{$slf->{'do_after_init'} // []} ) {
        my $task_and_args = shift @{$slf->{'do_after_init'}};
        my $method = shift @{$task_and_args};
        $slf->$method(@{$task_and_args})
    }
}

sub do_after_init {
    push @{$_[0]{'do_after_init'}}, $_[1]
}

sub initialized : lvalue { $_[0]{'initialized'} }

sub bc_mesg {
    my $slf = shift;
    $slf->do_after_init(['bc_mesg', @_]), return unless $slf->initialized;
    my $msg = $_[0];
    unless (defined $slf->{'chans'} and is_hashref($slf->{'chans'}) and %{$slf->{'chans'}}) {
        $slf->{'logger'}->error('No channels found to broadcast message to');
        return
    }
    my @chan_ids = keys %{$slf->{'chans'}{'by_id'}};
    my $n_chans = scalar @chan_ids;
    my $count_send = 0;
    for my $chan_id ( @chan_ids ) {
        $slf->{'bot'}->sendMessage({
            'chat_id'	=> $chan_id,
            'text'	=> $msg,
        } => sub {
            $slf->{'logger'}->debug(
                sprintf 'Message was sent succesfully to channel with id: %s', $chan_id
            );
            if ($count_send++ == $n_chans) {
               $slf->{'logger'}->debug(
                   sprintf 'Broadcast message was sent succesfully to channels: [[%s]]', join(']], [[' => keys %{$slf->{'chans'}{'by_title'}})
               )
            }
        })
    }
} # <- bc_mesg($message)

# Send simple message to channel:
# 	$telebot->mesg("channel name","your %s message", "awful", sub { callback });
sub mesg {
    my $slf = shift;
    $slf->do_after_init(['mesg', @_]), return unless $slf->initialized;
    
    my $chan = shift;
    for ($chan) { return unless defined() and ! ref() and $_ };

    my $log = $slf->{'logger'};
    my ($chan_id_or_err) =
        is_hashref($slf->{'chans'})
            ? $slf->{'chans'}{'by_title'}{$chan} //
                \sprintf('Cant send message: channel with the title <<%s>> not authorized yet', $chan)
            : \'Cant send message: no channels defined yet';
    if (is_scalarref $chan_id_or_err) {
        $log->error(${$chan_id_or_err});
        return
    }
    my $chan_id = $chan_id_or_err;
    my (@msg, $cb);
    for ( @_ ) {
        if ( defined() and !ref() ) {
            push @msg, $_
        } elsif ( is_coderef $_ ) {
            $cb = $_; last
        }
    }
    
    unless ( @msg ) {
        $log->error('Cant send message: where is your message, Luke?');
        return
    }
    
    my $text2send = $#msg
                      ? $msg[0] =~ /(?<!%)%[sdfg]/
                        ? sprintf($msg[0], @msg[1..$#msg])
                        : join(' ' => @msg)
                     : $msg[0];
                     
    $slf->{'bot'}->sendMessage({
            'chat_id' => $chan_id,
            'text'    => $text2send
        } => sub {
            $log->debug(sprintf 'message (length=%d) was sent to channel %s', length($text2send), $chan_id);
            $cb->() if $cb;
        });
} # <- mesg($chan, @message, $callback)

# Get list of subscribed telegram channels
sub chans {
    my $slf = $_[0];
    my @ch = 
        is_hashref($slf->{'chans'}{'by_title'})
            ? keys %{$slf->{'chans'}{'by_title'}}
            : ();
    return wantarray ? @ch : \@ch
} # <- chans()

sub wrap_async {
    my ($slf, $callback) = @_;
    sub {
        my (undef, $tx) = @_;
        my $response = eval { $tx->res->json } // {};
        unless (ref $response eq 'HASH' && %{$response} && $tx->res->is_success && $response->{'ok'}) {
            # TODO: if using this in production code, do NOT die on error, but handle them
            # gracefully
            say "ERROR: ", ($response->{'error_code'} ? "code $response->{'error_code'}: " : ""),
                $response->{'description'} ?
                    $response->{'description'} :
                    ($tx->error || {})->{'message'} || "something went wrong (for some unknown reasons :) )!";
            Mojo::IOLoop->stop unless $slf->{'no_loop'};
            exit
        }
        $callback->($response->{'result'});
    }
} # <- wrap_async()

sub DESTROY {
    $_[0]->stop;
}

1;
