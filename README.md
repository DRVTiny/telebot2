# DESCRIPTION

**TeleBot2** - is a Telegram bot to send broadcast notifications, such as that you can receive from your monitoring system.

It is used in production to send alerts from Zabbix to Telegram Chat Groups.

TeleBot2 is based on **[WWW::Telegram::BotAPI](https://github.com/Robertof/perl-www-telegram-botapi)** by RobertOf and uses only its "async" mode, so it will 
start Mojo::IOLoop event loop (with EV as backend) itself if you call constructor without "dont_manage_ev_loop" option.

Also, TeleBot2 strongly requires that you specify "logger" option, because otherwise it will use self-initialised Log::Dispatch logger 
(this behaviour is subject for change in the nearest future).

# EXAMPLE

```perl
$logger->logdie('Failed to create TeleBot object')
  unless my $tb=new TeleBot2(
    'bot_username'=>$botName,
    'dont_manage_ev_loop'=>1,
    'passphrase'=>($botConf->{'passphrase'} || DEFAULT_PASS_PHRASE),
    'logger'=>$logger,
  );
$tb->start;

$tb->mesg('CORP.Mon Notifications', 'Something awful require your attention');
```

# CONTACTS

Author: Andrey A. Konovalov aka DRVTiny <drvtiny AT google mail DOT com>

Mail me, please, or add an issue if you have any questions/suggestions.
