{ lib, config, pkgs, options, ... }:
let
  cfg = config.services.invidious;
  # To allow injecting secrets with jq, json (instead of yaml) is used
  settingsFormat = pkgs.formats.json { };
  inherit (lib) types;

  settingsFile = settingsFormat.generate "invidious-settings" cfg.settings;

  generatedHmacKeyFile = "/var/lib/invidious/hmac_key";
  generateHmac = cfg.hmacKeyFile == null;

  serviceConfig = {
    systemd.services.invidious = {
      description = "Invidious (An alternative YouTube front-end)";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = lib.optionalString generateHmac ''
        if [[ ! -e "${generatedHmacKeyFile}" ]]; then
          ${pkgs.pwgen}/bin/pwgen 20 1 > "${generatedHmacKeyFile}"
          chmod 0600 "${generatedHmacKeyFile}"
        fi
      '';

      script = ''
        configParts=()
      ''
      # autogenerated hmac_key
      + lib.optionalString generateHmac ''
        configParts+=("$(${pkgs.jq}/bin/jq -R '{"hmac_key":.}' <"${generatedHmacKeyFile}")")
      ''
      # generated settings file
      + ''
        configParts+=("$(< ${lib.escapeShellArg settingsFile})")
      ''
      # optional database password file
      + lib.optionalString (cfg.database.host != null) ''
        configParts+=("$(${pkgs.jq}/bin/jq -R '{"db":{"password":.}}' ${lib.escapeShellArg cfg.database.passwordFile})")
      ''
      # optional extra settings file
      + lib.optionalString (cfg.extraSettingsFile != null) ''
        configParts+=("$(< ${lib.escapeShellArg cfg.extraSettingsFile})")
      ''
      # explicitly specified hmac key file
      + lib.optionalString (cfg.hmacKeyFile != null) ''
        configParts+=("$(< ${lib.escapeShellArg cfg.hmacKeyFile})")
      ''
      # merge all parts into a single configuration with later elements overriding previous elements
      + ''
        export INVIDIOUS_CONFIG="$(${pkgs.jq}/bin/jq -s 'reduce .[] as $item ({}; . * $item)' <<<"''${configParts[*]}")"
        exec ${cfg.package}/bin/invidious
      '';

      serviceConfig = {
        RestartSec = "2s";
        DynamicUser = true;
        StateDirectory = "invidious";
        StateDirectoryMode = "0750";

        CapabilityBoundingSet = "";
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectProc = "invisible";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];

        # Because of various issues Invidious must be restarted often, at least once a day, ideally
        # every hour.
        # This option enables the automatic restarting of the Invidious instance.
        Restart = lib.mkDefault "always";
        RuntimeMaxSec = lib.mkDefault "1h";
      };
    };

    services.invidious.settings = {
      inherit (cfg) port;

      # Automatically initialises and migrates the database if necessary
      check_tables = true;

      db = {
        user = lib.mkDefault "kemal";
        dbname = lib.mkDefault "invidious";
        port = cfg.database.port;
        # Blank for unix sockets, see
        # https://github.com/will/crystal-pg/blob/1548bb255210/src/pq/conninfo.cr#L100-L108
        host = lib.optionalString (cfg.database.host != null) cfg.database.host;
        # Not needed because peer authentication is enabled
        password = lib.mkIf (cfg.database.host == null) "";
      };
    } // (lib.optionalAttrs (cfg.domain != null) {
      inherit (cfg) domain;
    });

    assertions = [{
      assertion = cfg.database.host != null -> cfg.database.passwordFile != null;
      message = "If database host isn't null, database password needs to be set";
    }];
  };

  # Settings necessary for running with an automatically managed local database
  localDatabaseConfig = lib.mkIf cfg.database.createLocally {
    # Default to using the local database if we create it
    services.invidious.database.host = lib.mkDefault null;


    # TODO(raitobezarius to maintainers of invidious): I strongly advise to clean up the kemal specific
    # thing for 24.05 and use `ensureDBOwnership`.
    # See https://github.com/NixOS/nixpkgs/issues/216989
    systemd.services.postgresql.postStart = lib.mkAfter ''
      $PSQL -tAc 'ALTER DATABASE "${cfg.settings.db.dbname}" OWNER TO "${cfg.settings.db.user}";'
    '';
    services.postgresql = {
      enable = true;
      ensureUsers = lib.singleton { name = cfg.settings.db.user; ensureDBOwnership = false; };
      ensureDatabases = lib.singleton cfg.settings.db.dbname;
      # This is only needed because the unix user invidious isn't the same as
      # the database user. This tells postgres to map one to the other.
      identMap = ''
        invidious invidious ${cfg.settings.db.user}
      '';
      # And this specifically enables peer authentication for only this
      # database, which allows passwordless authentication over the postgres
      # unix socket for the user map given above.
      authentication = ''
        local ${cfg.settings.db.dbname} ${cfg.settings.db.user} peer map=invidious
      '';
    };

    systemd.services.invidious-db-clean = {
      description = "Invidious database cleanup";
      documentation = [ "https://docs.invidious.io/Database-Information-and-Maintenance.md" ];
      startAt = lib.mkDefault "weekly";
      path = [ config.services.postgresql.package ];
      after = [ "postgresql.service" ];
      script = ''
        psql ${cfg.settings.db.dbname} ${cfg.settings.db.user} -c "DELETE FROM nonces * WHERE expire < current_timestamp"
        psql ${cfg.settings.db.dbname} ${cfg.settings.db.user} -c "TRUNCATE TABLE videos"
      '';
      serviceConfig = {
        DynamicUser = true;
        User = "invidious";
      };
    };

    systemd.services.invidious = {
      requires = [ "postgresql.service" ];
      after = [ "postgresql.service" ];

      serviceConfig = {
        User = "invidious";
      };
    };
  };

  nginxConfig = lib.mkIf cfg.nginx.enable {
    services.invidious.settings = {
      https_only = config.services.nginx.virtualHosts.${cfg.domain}.forceSSL;
      external_port = 80;
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.domain} = {
        locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";

        enableACME = lib.mkDefault true;
        forceSSL = lib.mkDefault true;
      };
    };

    assertions = [{
      assertion = cfg.domain != null;
      message = "To use services.invidious.nginx, you need to set services.invidious.domain";
    }];
  };
in
{
  options.services.invidious = {
    enable = lib.mkEnableOption (lib.mdDoc "Invidious");

    package = lib.mkPackageOption pkgs "invidious" { };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = lib.mdDoc ''
        The settings Invidious should use.

        See [config.example.yml](https://github.com/iv-org/invidious/blob/master/config/config.example.yml) for a list of all possible options.
      '';
    };

    hmacKeyFile = lib.mkOption {
      type = types.nullOr types.path;
      default = null;
      description = lib.mdDoc ''
        A path to a file containing the `hmac_key`. If `null`, a key will be generated automatically on first
        start.

        If non-`null`, this option overrides any `hmac_key` specified in {option}`services.invidious.settings` or
        via {option}`services.invidious.extraSettingsFile`.
      '';
    };

    extraSettingsFile = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = lib.mdDoc ''
        A file including Invidious settings.

        It gets merged with the settings specified in {option}`services.invidious.settings`
        and can be used to store secrets like `hmac_key` outside of the nix store.
      '';
    };

    # This needs to be outside of settings to avoid infinite recursion
    # (determining if nginx should be enabled and therefore the settings
    # modified).
    domain = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = lib.mdDoc ''
        The FQDN Invidious is reachable on.

        This is used to configure nginx and for building absolute URLs.
      '';
    };

    port = lib.mkOption {
      type = types.port;
      # Default from https://docs.invidious.io/Configuration.md
      default = 3000;
      description = lib.mdDoc ''
        The port Invidious should listen on.

        To allow access from outside,
        you can use either {option}`services.invidious.nginx`
        or add `config.services.invidious.port` to {option}`networking.firewall.allowedTCPPorts`.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = types.bool;
        default = true;
        description = lib.mdDoc ''
          Whether to create a local database with PostgreSQL.
        '';
      };

      host = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = lib.mdDoc ''
          The database host Invidious should use.

          If `null`, the local unix socket is used. Otherwise
          TCP is used.
        '';
      };

      port = lib.mkOption {
        type = types.port;
        default = options.services.postgresql.port.default;
        defaultText = lib.literalExpression "options.services.postgresql.port.default";
        description = lib.mdDoc ''
          The port of the database Invidious should use.

          Defaults to the the default postgresql port.
        '';
      };

      passwordFile = lib.mkOption {
        type = types.nullOr types.str;
        apply = lib.mapNullable toString;
        default = null;
        description = lib.mdDoc ''
          Path to file containing the database password.
        '';
      };
    };

    nginx.enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = lib.mdDoc ''
        Whether to configure nginx as a reverse proxy for Invidious.

        It serves it under the domain specified in {option}`services.invidious.settings.domain` with enabled TLS and ACME.
        Further configuration can be done through {option}`services.nginx.virtualHosts.''${config.services.invidious.settings.domain}.*`,
        which can also be used to disable AMCE and TLS.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    serviceConfig
    localDatabaseConfig
    nginxConfig
  ]);
}
