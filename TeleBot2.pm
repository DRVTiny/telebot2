#!/usr/bin/perl
# Async Telegram bot implementation using WWW::Telegram::BotAPI
# See also https://gist.github.com/Robertof/d9358b80d95850e2eb34
package TeleBot2;

use constant {
    INACT_TIMEOUT=>45,
    GET_UPD_TIMEOUT=>30,
    REDIS_DB_N=>10,
    DEFAULT_PASS_PHRASE=>'Perl is the best programming language in the world'
};

use utf8;
use 5.16.1;
use constant {
    
};
use EV;
use AnyEvent;
use Mojo::Base -strict;
use WWW::Telegram::BotAPI;
use JSON::XS;
use Log::Dispatch;
use Data::Dumper;
use Scalar::Util qw(refaddr blessed);
binmode $_, ':utf8' for *STDOUT, *STDERR;
use Redis;
my %aeh;

my %ext_pars=(
    'dont_manage_ev_loop'=>{
        'map'=>'no_loop'
    },
    'token'=>{
        'map'=>'token'
    },
    'redis_db_n'=>undef,
    'logger'=>undef,
    'passphrase'=>undef
);

sub new {
    my ($class, %pars)=@_;
    my $slf={'passphrase'=>DEFAULT_PASS_PHRASE};
    $slf->{(ref($ext_pars{$_}) eq 'HASH' and $ext_pars{$_}{'map'})?$ext_pars{$_}{'map'}:$_}=$pars{$_} 
        for grep defined $pars{$_}, keys %ext_pars;
    die 'You must provide token to create the '.__PACKAGE__.' object' 
        unless $slf->{'token'};
    $slf->{'redc'}=Redis->new;
    $slf->{'logger'}||=Log::Dispatch->new('outputs'=>[['Screen','min_level' => 'debug', 'newline' => 1, 'stderr' => 1]]);
    # Select Redis database we need to store our chan_id's
    $slf->{'redc'}->select($slf->{'redis_db_n'} || REDIS_DB_N);
    my $teleBot=$slf->{'bot'}=WWW::Telegram::BotAPI->new(
        'token' => $slf->{'token'},
        'async' => 1
    );
    
    # Increase the inactivity timeout of Mojo::UserAgent
    $teleBot->agent->inactivity_timeout (INACT_TIMEOUT);

    # If we have detected that "some_proxy" environment variables was set, tell our Mojo::UserAgent instance to use them
    $teleBot->agent->proxy->detect
        if grep defined $_, @ENV{map 'http'.$_.'_proxy', 's', ''};
    
    bless $slf, (ref $class || $class);
}

sub start {
    my $slf=shift;
    my $log=$slf->{'logger'};
    # Fetch bot information asynchronously
    $slf->{'bot'}->api_request('getMe', $slf->wrap_async(sub {
        my $me = shift;
        $slf->{'account'}=$me;
        $log->debug("Telegram bot << $me->{'first_name'} >> initialized and ready to fetch updates!");
        if (my %chans_by_id=eval { my %t=$slf->{'redc'}->hgetall('channels'); map { $_=>$t{$_} } grep /^-?\d+$/, keys %t }) {
            utf8::decode($_) for values %chans_by_id;
            $slf->{'chans'}{'by_id'}=\%chans_by_id;
            $slf->{'chans'}{'by_title'}={ map { $chans_by_id{$_} => $_ } keys %chans_by_id };
            $log->info( join("\n\t"=>'Loaded channels:', map join(' => #', each(%{$slf->{'chans'}{'by_title'}})), 1..scalar(keys %chans_by_id) ) );
        } else {
            $log->warn('No channels defined yet, waiting for updates to be possible to flood anywhere');
        }
        $slf->fetch_updates();
    }));
    unless ($slf->{'no_loop'}) {
        $SIG{'INT'}=sub { $log->warn('OOOOOOH, NO!! You interrupted me by Ctrl+C/Break pressing...'); Mojo::IOLoop->stop };
        Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
    }
}

sub stop {
    my $slf=shift;
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

# Async update handling
sub fetch_updates {
    my $slf=shift;
    my $log=$slf->{'logger'};
    state $offset = 0;
    $slf->{'bot'}->getUpdates ({
        'timeout' => GET_UPD_TIMEOUT,
        'allowed_updates' => ['message'], # remove me in production if you need multiple update types
        $offset ? ('offset' => $offset) : ()
    } => $slf->wrap_async( sub {
        my $updates = shift;
        for my $update (@$updates) {
            $log->debug( '+++++++++++ Received update: '.JSON::XS->new->pretty->encode($update));
            $offset = $update->{'update_id'} + 1 if $update->{'update_id'} >= $offset;
            # Handle text messages. No checks are needed because of `allowed_updates`
            my $message=$update->{'message'};
            my $message_text = $message->{'text'};
            $log->debug(sprintf("> Incoming message from \@%s:\n>> %s", join(' '=> @{$message->{'from'}}{map $_.'_name', qw(first last)}), $message_text));
            my ($chat_title,$chat_id)=@{$message->{'chat'}}{'title','id'};

            # For this example, we're just going to handle messages containing '/say something'
            given ($message_text) {
                when (/^\/say(?:\s+(.*))?$/i) {
                    # For this example, we don't care about the result of sendMessage.
                    $slf->{'bot'}->sendMessage ({
                        'chat_id' => $chat_id,
                        'text'    => $1?'You say: '.$1:'Oh, do you really have nothing to say?'
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
                                    $slf->{'chans'}{'by_id'   }{$chat_id   }=$chat_title;
                                    $slf->{'chans'}{'by_title'}{$chat_title}=$chat_id;
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
};

sub bc_mesg {
    my ($slf,$msg)=@_;
    unless (defined $slf->{'chans'} and ref $slf->{'chans'} eq 'HASH' and %{$slf->{'chans'}}) {
        $slf->{'logger'}->error('No channels found to broadcast message to');
        return
    }
    
    for my $chan_id (keys %{$slf->{'chans'}{'by_id'}}) {
        $slf->{'bot'}->sendMessage({
            'chat_id'=>$chan_id,
            'text'=>$msg,
        }=>sub { $slf->{'logger'}->debug('Message was sent succesfully')})
    }
}

sub mesg {
    my $slf=shift;    
    my ($chan,$msg)=map { return unless defined() and !ref() and $_ } @_;
    my $log=$slf->{'logger'};
    return unless my $chan_id=
        (ref $slf->{'chans'} eq 'HASH')
            ? $slf->{'chans'}{'by_title'}{$chan}
                ? $slf->{'chans'}{'by_title'}{$chan}
                : do { $log->error('Cant send message: channel with the title << '.$chan.' >> not authorized yet'); undef }
            : do {
                $log->error('Cant send message: no channels defined yet');
                undef
              };
    $slf->{'bot'}->sendMessage({'chat_id'=>$chan_id,'text'=>$msg},ref($_[2]) eq 'CODE'?$_[2]:sub{});
}

sub wrap_async {
    my ($slf,$callback) = @_;
    sub {
        my (undef, $tx) = @_;
        my $response = eval { $tx->res->json } || {};
        unless (ref $response eq 'HASH' && %{$response} && $tx->success && $response->{'ok'}) {
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
}

sub DESTROY {
    $_[0]->stop;
}

1;
