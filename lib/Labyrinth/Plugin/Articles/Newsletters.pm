package Labyrinth::Plugin::Articles::Newsletters;

use warnings;
use strict;

use vars qw($VERSION);
$VERSION = '1.00';

=head1 NAME

Labyrinth::Plugin::Articles::Newsletters - Newsletters plugin handler for Labyrinth

=head1 DESCRIPTION

Contains all the article handling functionality for Newsletters.

=cut

# -------------------------------------
# Library Modules

use base qw(Labyrinth::Plugin::Articles);

use Labyrinth::Audit;
use Labyrinth::MLUtils;
use Labyrinth::Support;
use Labyrinth::Variables;

use Session::Token;

# -------------------------------------
# Variables

our $LEVEL      = EDITOR;
my $LEVEL2      = ADMIN;

# sectionid is used to reference different types of articles,
# however, the default is also a standard article.
my $SECTIONID   = 12;

# type: 0 = optional, 1 = mandatory
# html: 0 = none, 1 = text, 2 = textarea

my %fields = (
    articleid   => { type => 0, html => 0 },
    title       => { type => 1, html => 1 },
);

my (@mandatory,@allfields);
for(keys %fields) {
    push @mandatory, $_     if($fields{$_}->{type});
    push @allfields, $_;
}

my %email_fields = (
    name    => { type => 1, html => 1 },
    email   => { type => 1, html => 1 },
);

my (@email_man,@email_all);
for(keys %email_fields) {
    push @email_man, $_     if($email_fields{$_}->{type});
    push @email_all, $_;
}

my %code_fields = (
    id      => { type => 1, html => 1 },
    code    => { type => 1, html => 1 },
);

my (@code_man,@code_all);
for(keys %code_fields) {
    push @code_man, $_     if($code_fields{$_}->{type});
    push @code_all, $_;
}

my %subs_fields = (
    subscriptions   => { type => 1, html => 1 },
);

my (@subs_man,@subs_all);
for(keys %subs_fields) {
    push @subs_man, $_     if($subs_fields{$_}->{type});
    push @subs_all, $_;
}

my $gen = Session::Token->new(length => 24);

# -------------------------------------
# The Subs

=head1 PUBLIC INTERFACE METHODS

=over 4

=item Section

Sets for Newsletter Articles within the system.

=item Subscribe

Single user subscription process. To be used by users who wish to sign up to 
the newsletters. Starts the subscription process. 

=item Subscribed

Last part of the subscription process.

=item UnSubscribe

Single user unsubscription process. To be used by users who have previously 
signing up for the newsletters. Starts the unsubscription process. 

=item UnSubscribed

Last part of the unsubscription process.

=back

=cut

sub Section {
    $cgiparams{sectionid} = $SECTIONID;
}

sub Subscribe {
    # requires: name, email
    for(keys %email_fields) {
           if($email_fields{$_}->{html} == 1) { $cgiparams{$_} = CleanHTML($cgiparams{$_}); }
        elsif($email_fields{$_}->{html} == 2) { $cgiparams{$_} =  SafeHTML($cgiparams{$_}); }
    }

    return  if FieldCheck(\@email_all,\@email_man);

    # already exists?
    my @email = $dbi->GetQuery('hash','CheckSubscptionEmail',$tvars{data}{email});
    if(@email && !$tvars{data}{resend}) {
        $tvars{resend} = 1;
        $tvars{email} = $tvars{data}{email};
        return;
    }

    $code = $gen->get();
    my $userid;

    if(@email) {
        $userid = $email[0]->{userid};
        $dbi->DoQuery('UpdateUnConfirmedEmail',$userid,$tvars{data}{email},$code);
    } else {
        $userid = $dbi->IDQuery('InsertSubscriptionEmail',$tvars{data}{name},$tvars{data}{email},$code);
    }

    MailSend(   template        => '',
                name            => $tvars{data}{name},
                recipient_email => $tvars{data}{email},
                code            => "$code/$userid",
                webpath         => "$tvars{docroot}$tvars{webpath}",
                nowrap          => 1
    );

    $tvars{errcode} = 'BADMAIL' if(!MailSent());
}

sub Subscribed {
    # requires: keycode, id
    for(keys %code_fields) {
           if($code_fields{$_}->{html} == 1) { $cgiparams{$_} = CleanHTML($cgiparams{$_}); }
        elsif($code_fields{$_}->{html} == 2) { $cgiparams{$_} =  SafeHTML($cgiparams{$_}); }
    }

    return  if FieldCheck(\@code_all,\@code_man);

    my @email = $dbi->GetQuery('hash','CheckSubscriptionKey',$tvars{data}{code},$tvars{data}{id});
    if(@email) {
        $dbi->DoQuery('ConfirmedSubscription',$tvars{data}{id});
        $tvars{success} = 1;
    }
}

sub UnSubscribe {
    # requires: email
    return  unless($cgiparams{email});

    # doesn't exist?
    my @email = $dbi->GetQuery('hash','CheckSubscptionEmail',$cgiparams{email});
    return  unless(@email);

    $dbi->DoQuery('RemoveSubscription',$email[0]->{userid});
    $tvars{success} = 1;
}

=head1 ADMIN INTERFACE METHODS

=over 4

=item AdminSubscription

=item BulkSubscription

=item DeleteSubscription

=back

=cut

sub AdminSubscription {
    return  unless AccessUser($LEVEL);

    my @emails = $dbi->GetQuery('hash','ListSubscptions');
    $tvars{emails} = \@emails   if(@emails);
}

sub BulkSubscription {
    return  unless AccessUser($LEVEL);

    # requires: subscriptions
    for(keys %code_fields) {
           if($code_fields{$_}->{html} == 1) { $cgiparams{$_} = CleanHTML($cgiparams{$_}); }
        elsif($code_fields{$_}->{html} == 2) { $cgiparams{$_} =  SafeHTML($cgiparams{$_}); }
    }

    return  if FieldCheck(\@code_all,\@code_man);
    my @subs = split(qr/\s+/,$tvars{data}{subscriptions});
    for my $sub {@subs) {
        my ($name,$email) = split(',',$sub);
        $dbi->DoQuery('InsertSubscriptionEmail',$name,$email,'');
    }
}

sub DeleteSubscription {
    return  unless AccessUser($LEVEL);
    
    my @ids = CGIArray('LISTED');
    $dbx->DoQuery('RemoveSubscription',$_)  for(@ids);
}

sub SendNewsletter {
    return  unless AccessUser($LEVEL);
    my @users = $dbi->GetQuery('hash','GetSubscribers');

    my ($id,$users) = ($cgiparams{$INDEXKEY},\@users);

    my %opts = (
        html    => 'mailer/newsletter.html',
        nowrap  => 1,
        from    => $tvars{data}{hFrom},
        subject => $tvars{data}{hSubject}
    );

    $tvars{gotusers} = scalar(@users);

    # get newsletter details
    return  unless AuthorCheck($GETSQL,$INDEXKEY,$LEVEL);

    $tvars{mailsent} = 0;

    for my $user (@$users) {
        $opts{body}     = $tvars{data}{body};
        $opts{vars}     = \%tvars;

        $user->{realname} = decode_entities($user->{realname} );

        my $t = localtime;
        $opts{edate}            = $t->strftime("%a, %d %b %Y %H:%M:%S +0000");
        $opts{email}            = $user->{email} or next;
        $opts{recipient_email}  = $user->{email} or next;
        $opts{ename}            = $user->{realname} || '';

        for my $key (qw(from subject body)) {
            $opts{$key} =~ s/ENAME/$user->{realname}/g;
            $opts{$key} =~ s/EMAIL/$user->{email}/g;

            $opts{$key} =~ s/\r/ /g;    # a bodge
        }

#use Data::Dumper;
#LogDebug("opts=".Dumper(\%opts));
        HTMLSend(%opts);
        $dbi->DoQuery('InsertNewsletterIndex',$cgiparams{$INDEXKEY},$user->{userid},time());

        # if sent update index
        $tvars{mailsent}++  if(MailSent());
    }

    $tvars{thanks} = $tvars{mailsent} ? 2 : 3;
}

1;

__END__

=head1 SEE ALSO

  Labyrinth

=head1 AUTHOR

Barbie, <barbie@missbarbell.co.uk> for
Miss Barbell Productions, L<http://www.missbarbell.co.uk/>

=head1 COPYRIGHT & LICENSE

  Copyright (C) 2002-2014 Barbie for Miss Barbell Productions
  All Rights Reserved.

  This distribution is free software; you can redistribute it and/or
  modify it under the Artistic Licence v2.

=cut
