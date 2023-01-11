# DESCRIPTION

**TeleBot2** - is a Telegram bot which mainly usage scenario is sending broadcast notifications as a reaction on some external events, such as what you can receive from your monitoring system.

It is used in production to send alerts from Zabbix to Telegram Chat Groups.

TeleBot2 is based on **[WWW::Telegram::BotAPI](https://github.com/Robertof/perl-www-telegram-botapi)** by RobertOf and uses only its "async" mode, so it will 
start Mojo::IOLoop event loop (with EV as backend) itself if you call constructor without "dont_manage_ev_loop" option.

Also, TeleBot2 strongly requires that you specify "logger" option, because otherwise it will use self-initialised Log::Dispatch logger 
(this behaviour is subject for change in the nearest future).

# EXAMPLE

```perl
use TeleBot2;
use YAML;
my $logger = ...;
my $botConf = Load(PATH_TO_YAML_CONFIG);
my $tb = TeleBot2->new(
    'bot_username' => $botName,
    'dont_manage_ev_loop' => 1,
    'passphrase' => ($botConf->{'passphrase'} || DEFAULT_PASS_PHRASE),
    'logger' => $logger
) or $logger->logdie('Failed to create TeleBot object');

$tb->start;

Mojo::IOLoop->recurring(10 => sub {
  $tb->mesg('CORP.Mon Notifications', 'Something awful require your attention');
  $tb->bc_mesg('To ALL whom concerned: disaster, total destruction, save our souls!');
});

# Because we denied TeleBot2 to start Mojo::IOLoop by itself using 'dont_manage_ev_loop' option:
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
```

# CONTACTS

Author: Andrey A. Konovalov aka DRVTiny <drvtiny AT google mail DOT com>

Please, feel free to mail me or add an issue if you have any questions/suggestions.
