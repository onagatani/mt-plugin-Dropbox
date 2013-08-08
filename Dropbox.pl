package MT::Plugin::Dropbox;
use strict;
use warnings;
use base qw( MT::Plugin );
use WebService::Dropbox;
use Time::Piece;
use URI;

our $PLUGIN = 'Dropbox';
our $VERSION = '0.2';

my $plugin = __PACKAGE__->new(+{
    name           => $PLUGIN,
    version        => $VERSION,
    key            => lc $PLUGIN,
    id             => lc $PLUGIN,
    author_name    => 'onagatani',
    author_link    => 'http://onagatani.com/',
    description    => q{<MT_TRANS phrase="Dropbox utility">},
    l10n_class     => $PLUGIN. '::L10N',
    registry => +{
        tasks => +{
            dropbox_backup => +{
                name        => 'DropboxBackup',
                frequency   => 60 * 60 * 24,
                code        => \&_dropbox_backup,
            },
        },
        applications => +{
            cms => +{
                methods => +{
                    dropbox_callback => \&_dropbox_callback,
                    dropbox_auth     => \&_dropbox_auth,
                },
                menus => +{
                    'tools:dropbox_auth' => +{
                        label             => "dropbox auth",
                        order             => 10100,
                        mode              => 'dropbox_auth',
                        permission        => 'administer',
                        system_permission => 'administer',
                        view              => 'system',
                    },
                },
            },
        },
    },
    settings => MT::PluginSettings->new([
        ['dropbox_path',   { Default => undef , Scope => 'system' }],
        ['app_key',        { Default => undef , Scope => 'system' }],
        ['app_secret',     { Default => undef , Scope => 'system' }],
        ['request_secret', { Default => undef , Scope => 'system' }],
        ['request_token',  { Default => undef , Scope => 'system' }],
        ['access_token',   { Default => undef , Scope => 'system' }],
        ['access_secret',  { Default => undef , Scope => 'system' }],
    ]),
    system_config_template => \&_system_config,
});

MT->add_plugin( $plugin );

sub _dropbox_callback {
    my $app = shift;

    return $app->trans_error('Invalid request.') unless _check_perm();

    my $config = $plugin->get_config_hash;

    return $app->trans_error('Invalid request.') 
        unless $config->{request_token} || $config->{request_secret};

    my $dropbox = WebService::Dropbox->new({
        key            => $config->{app_key},
        secret         => $config->{app_secret},
        request_token  => $config->{request_token},
        request_secret => $config->{request_secret},
    });
    $dropbox->auth or die MT->log($dropbox->error);

    $plugin->set_config_value('access_token', $dropbox->access_token, 'system');
    $plugin->set_config_value('access_secret', $dropbox->access_secret, 'system');

    return $app->return_to_dashboard;
}

sub _dropbox_auth {
    my $app = shift;

    return $app->trans_error('Invalid request.') unless _check_perm();

    my $config = $plugin->get_config_hash;

    return $app->return_to_dashboard unless $config->{app_key} or $config->{app_secret};

    my $uri = URI->new_abs(
        $app->mt_uri(mode => 'dropbox_callback'), $app->base
    );
    
    my $dropbox = WebService::Dropbox->new({
        key    => $config->{app_key},
        secret => $config->{app_secret},
    });
    my $url = $dropbox->login($uri) or die MT->log($dropbox->error);

    $plugin->set_config_value('request_token', $dropbox->request_token, 'system');
    $plugin->set_config_value('request_secret', $dropbox->request_secret, 'system');

    return $app->redirect($url);
}


sub _dropbox_backup {
    my $cb = shift;

    my $cfg  = MT->config;

    my $time = localtime;

    my $file = sprintf'%s-%s.sql.gz', $cfg->Database, $time->ymd;

    unlink "/tmp/$file";

    my $mysqldump = $cfg->MySQLDumpPath || '/usr/bin/mysqldump';
    my $gzip = $cfg->GZipPath || '/usr/bin/gzip';

    my $command = sprintf'%s -q -c -u%s -p%s --default-character-set=utf8 %s | %s > /tmp/%s 2>&1',
        $mysqldump, $cfg->DBUser, $cfg->DBPassword, $cfg->Database, $gzip, $file;

    `$command`;

    my $config = $plugin->get_config_hash;

    my $dropbox = WebService::Dropbox->new({
        key            => $config->{app_key},
        secret         => $config->{app_secret},
        access_token   => $config->{access_token},
        access_secret  => $config->{access_secret},
    });

    open my $fh, '<', "/tmp/$file" or die $!;

    my $uploadpath = sprintf'%s/%s', $config->{dropbox_path}, $file;

    $dropbox->files_put($uploadpath, $fh, { overwrite => 1 }) or
        die MT->log($dropbox->error);

    close $fh;

    unlink "/tmp/$file";
}

sub _system_config {
    return <<'__HTML__';
<mtapp:setting id="dropbox_path" label="<__trans phrase="dropbox path">">
<input type="text" name="dropbox_path" value="<$mt:getvar name="dropbox_path" escape="html"$>" />
<p class="hint"><__trans phrase="Dropbox Backup Path"></p>
</mtapp:setting>

<mtapp:setting id="app_key" label="<__trans phrase="app key">">
<input type="text" name="app_key" value="<$mt:getvar name="app_key" escape="html"$>" />
<p class="hint"><__trans phrase="Dropbox Application key"></p>
</mtapp:setting>

<mtapp:setting id="app_secret" label="<__trans phrase="app secret">">
<input type="text" name="app_secret" value="<$mt:getvar name="app_secret" escape="html"$>" />
<p class="hint"><__trans phrase="Dropbox Application secret"></p>
</mtapp:setting>

<mtapp:setting id="access_token" label="<__trans phrase="access token">">
<$mt:getvar name="access_token" escape="html"$>
<p class="hint"><__trans phrase="Dropbox Access token"></p>
</mtapp:setting>

<mtapp:setting id="access_secret" label="<__trans phrase="access secret">">
<$mt:getvar name="access_secret" escape="html"$>
<p class="hint"><__trans phrase="Dropbox Access secret"></p>
</mtapp:setting>

__HTML__
}

sub _check_perm { 
    my $user = MT->instance->user or return;
    my $sys_perm = $user->permissions(0);
    if ($user->is_superuser || ($sys_perm and $sys_perm->can_do('administer')) ) {
        return 1;
    }
}

1;
__END__