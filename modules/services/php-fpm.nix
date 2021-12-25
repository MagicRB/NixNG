# SPDX-FileCopyrightText:  2021 Richard Brežák and NixNG contributors
#
# SPDX-License-Identifier: MPL-2.0
#
#   This Source Code Form is subject to the terms of the Mozilla Public
#   License, v. 2.0. If a copy of the MPL was not distributed with this
#   file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This file incorporates work sublicensed from the MIT License to
# Mozilla Public License, v. 2.0, for which the following copyright applies:
#   Copyright (c) 2003-2021 Eelco Dolstra and the Nixpkgs/NixOS contributors

{ pkgs, config, lib, nglib, ... }:
with lib;
let
  cfg = config.services.php-fpm;

  runtimeDir = "/run/php-fpm/";

  genPhpIniFile = { settings, package }: pkgs.runCommandNoCC "php.ini"
    {
      phpSettings = settings;
      phpGlobalSettings = cfg.phpSettings;
      passAsFile = [ "phpSettings" "phpGlobalSettings" ];
      preferLocalBuild = true;
    }
    ''
      cat ${package}/etc/php.ini $phpGlobalSettingsPath $phpSettingsPath > $out
    '';

  genFpmConfFile = { settings }: pkgs.runCommandNoCC "php-fpm.conf"
    {
      fpmSettings = settings;
      fpmGlobalSettings = cfg.fpmSettings;
      passAsFile = [ "fpmSettings" "fpmGlobalSettings" ];
      preferLocalBuild = true;
    }
    ''
      cat $fpmGlobalSettingsPath $fpmSettingsPath > $out
    '';

  poolOpts = { name, ... }: {
    options = {
      socket = mkOption {
        type = types.str;
        readOnly = true;
        description = ''
          Path to the unix socket file on which to accept FastCGI requests.
          <node><para>This options is read-only and managed by NixOS.</para></note>
        '';
        example = "${runtimeDir}<name>.sock";
      };

      createUserGroup = mkOption {
        description = ''
          Whether to create the default user <literal>www-data</literal>
          and group <literal>www-data</literal>.
        '';
        type = types.bool;
        default = true;
      };

      fpmSettings = mkOption {
        type = with types; attrsOf (oneOf [ str int bool ]);
        default = { };
        description = ''
          PHP-FPM global directives. Refer to the "List of global php-fpm.conf directives" section of
          <link xlink:href="https://www.php.net/manual/en/install.fpm.configuration.php"/>
          for details. Note that settings names must be enclosed in quotes (e.g.
          <literal>"pm.max_children"</literal> instead of <literal>pm.max_children</literal>).
          You need not specify the options <literal>error_log</literal> or
          <literal>daemonize</literal> here, since they are generated by NixNG.
        '';
      };

      phpSettings = mkOption {
        type = with types; attrsOf (oneOf [ str int bool ]);
        default = { };
        example = literalExample ''
          {
            "date.timezone" = "CET";
          }
        '';
        description = ''
          Options for PHP configuration files <filename>php.ini</filename>.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.php74;
        description = ''
          The PHP package to use for running this PHP-FPM pool.
        '';
      };

      environment = mkOption {
        type = with types; attrsOf (oneOf [ str int bool ]);
        default = { };
        description = ''
          Environment variables used for this PHP-FPM pool.
        '';
        example = literalExample ''
          {
            HOSTNAME = "$HOSTNAME";
            TMP = "/tmp";
            TMPDIR = "/tmp";
            TEMP = "/tmp";
          }
        '';
      };
    };

    config = {
      socket = "${runtimeDir}/${name}.sock";
      fpmSettings = mapAttrs (_: mkDefault) {
        user = "www-data";
        group = "www-data";
        listen = cfg.pools.${name}.socket;
        "listen.owner" = "www-data";
        "listen.group" = "www-data";
        "listen.mode" = "0660";
      };
    };
  };
in
{
  options.services.php-fpm = {
    fpmSettings = mkOption {
      type = with types; attrsOf (oneOf [ str int bool ]);
      default = { };
      apply = x: nglib.generators.php.fpm { } x "global";
      description = ''
        PHP-FPM global directives. Refer to the "List of global php-fpm.conf directives" section of
        <link xlink:href="https://www.php.net/manual/en/install.fpm.configuration.php"/>
        for details. Note that settings names must be enclosed in quotes (e.g.
        <literal>"pm.max_children"</literal> instead of <literal>pm.max_children</literal>).
        You need not specify the options <literal>error_log</literal> or
        <literal>daemonize</literal> here, since they are generated by NixNG.
        Each pools config will be prepended with these.
      '';
    };

    phpSettings = mkOption {
      type = with types; attrsOf (oneOf [ str int bool ]);
      default = { };
      apply = nglib.generators.php.ini;
      example = literalExample ''
        {
          "date.timezone" = "CET";
        }
      '';
      description = ''
        Global options for PHP configuration files <filename>php.ini</filename>.
        Each pool's config will be prepended with these.
      '';
    };

    pools = mkOption {
      type = with types; attrsOf (submodule poolOpts);
      default = { };
      description = ''
        PHP-FPM "pools", think of each pool as a separate php-fpm instance.
        If none are defined, the php-fpm service module does nothing.
      '';
    };
  };

  config =
    mkIf (cfg.pools != { }) {
      services.php-fpm.fpmSettings = {
        daemonize = false;
      };

      init.services = mapAttrs'
        (pool: opts:
          nameValuePair "php-fpm-${pool}" {
            enabled = true;
            ensureSomething.create."runtimeDir" = {
              type = "directory";
              dst = runtimeDir;
              # TODO: shouldn't be persistent but we could delete a socket
              # from another pool
              persistent = true;
            };
            script =
              let
                phpIniFile = genPhpIniFile
                  {
                    settings = nglib.generators.php.ini opts.phpSettings;
                    package = opts.package;
                  };

                phpFpmConfFile = genFpmConfFile
                  {
                    settings = nglib.generators.php.fpm opts.environment opts.fpmSettings pool;
                  };
              in
              pkgs.writeShellScript "php-fpm-${pool}-run"
                ''
                  echo HELLO
                  ${opts.package}/bin/php-fpm -y ${phpFpmConfFile} -c ${phpIniFile}
                '';
          }
        )
        cfg.pools;

      users.users = builtins.listToAttrs (filter (x: x.value != null)
        (mapAttrsToList
          (pool: opts:
            let
              user = opts.phpSettings.user;
            in
            nameValuePair user
              (if opts.createUserGroup then
                {
                  description = "PHP-FPM - ${pool}";
                  group = user;
                  createHome = false;
                  home = "/var/empty";
                  useDefaultShell = true;
                  uid = config.ids.uids.${user};
                }
              else
                null)
          )
          cfg.pools));

      users.groups = builtins.listToAttrs (filter (x: x.value != null)
        (mapAttrsToList
          (pool: opts:
            let
              group = opts.phpSettings.group;
            in
            nameValuePair group
              (if opts.createUserGroup then
                {
                  gid = config.ids.gids.${group};
                }
              else
                null)
          )
          cfg.pools));
    };
}