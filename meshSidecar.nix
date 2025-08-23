{
  config,
  options,
  pkgs,
  lib,
  ...
}: {
  options.services.meshSidecar = {
    enable = lib.mkEnableOption "meshSidecar module";

    provider = lib.mkOption {
      type = lib.types.enum ["tailscale" "netbird"];
      description = ''Mesh network service provider e.g. currently "tailscale" or "netbird".'';
      default = "tailscale";
    };

    # TODO: support providing multiple, tied to service. support multiple mesh providers at once?
    authKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to key file for mesh provider auth.";
    };

    outboundInterface = lib.mkOption {
      type = lib.types.str;
      description = "Name of the outbound network interface.";
    };

    bridgeName = lib.mkOption {
      type = lib.types.addCheck lib.types.str (
        name:
          builtins.stringLength name <= 15 && name != ""
      );
      description = "Name of the bridge interface.";
      default = "meshBridge";
    };

    bridgeCidr = lib.mkOption {
      type = lib.types.str;
      description = "Bridge IP address and subnet in CIDR notation (e.g., 192.168.222.1/24).";
      default = "192.168.222.1/24";
    };

    dhcpRange = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        DHCP range as a two-element list of IP addresses, e.g. [ "192.168.222.2" "192.168.222.254" ].
      '';
      # TODO: split into two options? test/assert its length two?
      default = ["192.168.222.2" "192.168.222.254"];
    };

    #upstreamDns = lib.mkOption {
    #  type = lib.types.listOf lib.types.str;
    #  description = ''
    #    List of upstream DNS server IP addresses to use for DNS resolution.
    #    Example: [ "8.8.8.8" "1.1.1.1" ]
    #  '';
    #  default = ["1.1.1.1" "8.8.8.8"];
    #};

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          meshName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname to use on the mesh network. Defaults to service name.";
          };
        };
      });
      default = {};
      description = "Services to wrap with mesh networking";
    };

    knownServiceOverrides = lib.mkOption {
      type = lib.types.submodule {
        options = {
          paperless.enable = lib.mkEnableOption "Apply paperless-specific overrides";
        };
      };
      default = {};
      description = "Enable known service integration overrides";
    };
  };

  config = let
    # Grab our module config
    cfg = config.services.meshSidecar;
    # Bind required bins
    ip = "${pkgs.iproute2}/bin/ip";
    iptables = "${pkgs.iptables}/bin/iptables";
    mount = "${pkgs.utillinux}/bin/mount";
    umount = "${pkgs.utillinux}/bin/umount";
    udhcpd = "${pkgs.busybox}/bin/udhcpd";
    udhcpc = "${pkgs.busybox}/bin/udhcpc";
    # Bind required libs
    writeText = pkgs.writeText;
    writeDash = pkgs.writers.writeDash;
    concatStringsSep = pkgs.lib.concatStringsSep;
    # Derived config data
    dhcpRouter = builtins.elemAt (builtins.split "/" cfg.bridgeCidr) 0;
    dhcpStart = builtins.elemAt cfg.dhcpRange 0;
    dhcpEnd = builtins.elemAt cfg.dhcpRange 1;
    # TODO: method to support more than two providers cleanly
    serviceOverrides =
      lib.mapAttrs (serviceName: serviceConfig: {
        bindsTo =
          if cfg.provider == "netbird"
          then ["netbird@%N.service"]
          else ["tailscale@%N.service"];
        after =
          if cfg.provider == "netbird"
          then ["netbird@%N.service"]
          else ["tailscale@%N.service"];
        unitConfig.JoinsNamespaceOf =
          if cfg.provider == "netbird"
          then "netbird@%N.service"
          else "tailscale@%N.service";
        # doesn't change based on mesh provider
        serviceConfig.PrivateNetwork = true;
        serviceConfig.BindPaths = ["/etc/netns/%N/resolv.conf:/etc/resolv.conf"];
      })
      cfg.services;
    meshNameMap = lib.mapAttrs (k: v:
      if v.meshName != null
      then v.meshName
      else k)
    cfg.services;
    meshNameMapJSON = builtins.toJSON meshNameMap;
    moduleServices = {
      "systemdbridge" = {
        before = ["network.target"];
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          PrivateMounts = true;
          ProtectSystem = "strict";
          RuntimeDirectory = "systemdbridge";
          # N.B. udhcpd writes it's lease file to /var/lib/misc
          BindPaths = "/run/systemdbridge:/var/lib/misc";
          # TODO: configurable outbound interface or autodiscovery?
          ExecStart = "${
            writeDash "${cfg.bridgeName}-up" ''
              set -x
              # TODO: export needed?
              export PATH=${pkgs.busybox}/bin
              ${ip} link add ${cfg.bridgeName} type bridge
              ${ip} addr add ${cfg.bridgeCidr} dev ${cfg.bridgeName}
              ${ip} link set ${cfg.bridgeName} up
              # Enable NAT
              # TODO: add -s (e.g. 192.168.222.0/24, may need cfg changes for how we pass this info)
              ${iptables} -t nat -A POSTROUTING -o ${cfg.outboundInterface} -j MASQUERADE
              # Allow outbound traffic from our bridge and private services
              ${iptables} -A FORWARD -i ${cfg.bridgeName} -o ${cfg.outboundInterface} -j ACCEPT
              # Allow return traffic
              ${iptables} -A FORWARD -i ${cfg.outboundInterface} -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
              ${iptables} -A FORWARD -i ${cfg.outboundInterface} -o ${cfg.bridgeName} -j DROP
              # Allow DHCP (N.B. -I for accept to handle nixos-fw being active)
              ${iptables} -I INPUT -i ${cfg.bridgeName} -p udp --dport 67 -j ACCEPT
              ${iptables} -A INPUT -i ${cfg.bridgeName} -j DROP
              #${udhcpd} -f ${writeText "udhcpd-cfg" "interface ${cfg.bridgeName}\nstart ${dhcpStart}\nend ${dhcpEnd}\noption router ${dhcpRouter}\noption dns 1.1.1.1\n"}
              ${udhcpd} -f ${writeText "udhcpd-cfg" "interface ${cfg.bridgeName}\nstart ${dhcpStart}\nend ${dhcpEnd}\noption router ${dhcpRouter}\n"}
            ''
          }";
          ExecStop = "${
            writeDash "${cfg.bridgeName}-down" ''
              set -x
              # Delete bridge
              ${ip} link del ${cfg.bridgeName}
              # Cleanup leftover iptables rules
              ${iptables} -t nat -D POSTROUTING -o ${cfg.outboundInterface} -j MASQUERADE
              ${iptables} -D FORWARD -i ${cfg.bridgeName} -o ${cfg.outboundInterface} -j ACCEPT
              ${iptables} -D FORWARD -i ${cfg.outboundInterface} -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
              ${iptables} -D FORWARD -i ${cfg.outboundInterface} -o ${cfg.bridgeName} -j DROP
              ${iptables} -D INPUT -i ${cfg.bridgeName} -p udp --dport 67 -j ACCEPT
              ${iptables} -D INPUT -i ${cfg.bridgeName} -j DROP
            ''
          }";
        };
      };

      "defaultnetns" = {
        before = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = "${ip} netns del default";
          ExecStart = "${
            writeDash "defaultnetns-up" ''
              set -x
              ${ip} netns add default
              ${umount} /var/run/netns/default
              ${mount} --bind /proc/1/ns/net /var/run/netns/default
            ''
          }";
        };
      };

      "netns-publisher" = {
        description = "netns publisher via socket";
        after = ["netns-publisher.socket"];
        requires = ["netns-publisher.socket"];
        serviceConfig = {
          ExecStart = writeDash "netns-publisher-up" "${pkgs.python313}/bin/python3 -u ${./netns-publisher.py}";
          StandardInput = "socket"; # systemd passed FD 0
          StandardOutput = "journal";
          StandardError = "journal";
          Restart = "always";
        };
      };

      "netns@" = {
        description = "%i network namespace";
        partOf = ["netbird@%i.service" "tailscale@%i.service"];
        bindsTo = ["systemdbridge.service" "defaultnetns.service"];
        after = ["defaultnetns.service" "netns-publisher.service"];
        wants = ["netns-publisher.service"];
        before = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateNetwork = true;
          ConfigurationDirectory = "netns/%i";
          PrivateMounts = false; # TODO...
          # TODO: make per-service configurable
          PrivateTmp = true;
          ExecStart = "${
            writeDash "netns-up" (''
                set -x
                # Linux interface name max is 15 char
                VETH_NAME=$(printf "%.15s" "$1")
                #${ip} netns add "$1"
                #${umount} "/var/run/netns/$1"
                #${mount} --bind /proc/self/ns/net "/var/run/netns/$1"
                # publish netns
                ${pkgs.python313}/bin/python3 ${./send-netns.py} "$1" A
                ${ip} link add "$VETH_NAME" type veth peer name eth0
                ${ip} link set eth0 up
                ${ip} link set netns default dev "$VETH_NAME"
                ${ip} netns exec default ${ip} link set "$VETH_NAME" master ${cfg.bridgeName}
                ${ip} netns exec default ${ip} link set ${cfg.bridgeName} up
                ${ip} netns exec default ${ip} link set "$VETH_NAME" up

                #${ip} netns exec default cat /etc/nsswitch.conf > "/etc/netns/$1/nsswitch.conf"
                #echo 'hosts: dns' > "/etc/netns/$1/nsswitch.conf"

                touch "/etc/netns/$1/resolv.conf"
                ${ip} netns exec "$1" ${udhcpc} -f -q -n -t 3 -T 3 -i eth0
                # TODO: patch udhcpc to only overwrite when dns option is present
                # until then, we just overwrite after it runs
                # TODO: needs magic dns if we want tailscale to manage, if non-empty.
                # leaving empty for now as this does not break tailscale
                #${ip} netns exec default cat /etc/resolv.conf > "/etc/netns/$1/resolv.conf"
                #cat "/etc/netns/$1/resolv.conf"
              ''
              + (
                if cfg.provider == "netbird"
                then "\n${ip} netns exec default cat /etc/resolv.conf > /etc/netns/\"$1\"/resolv.conf\n"
                else ""
              ))
          } %i";
          ExecStopPost = "${
            writeDash "netns-down" ''
              set +x
              # Linux interface name max is 15 char
              VETH_NAME=$(printf "%.15s" "$1")
              ${ip} netns exec default ${ip} link del "$VETH_NAME"
              # TODO: can't work with PrivateTmp
              #${umount} "/var/run/netns/$1"
              #${ip} netns del "$1"
              # TODO: add RM!
              #rm -rf "/etc/netns/$1"
              ${pkgs.python313}/bin/python3 ${./send-netns.py} "$1" D
            ''
          } %i";
        };
      };

      "netbird@" = {
        enable = true;
        partOf = ["%i.service"];
        bindsTo = ["netns@%i.service"];
        after = ["netns@%i.service"];
        unitConfig.JoinsNamespaceOf = "netns@%i.service";
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          LoadCredential = "auth-key:${cfg.authKeyFile}";
          ExecStart = "${writeDash "netbird-up" ''
            set -x
            MESH_NAME=$(echo '${meshNameMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // $service')
            ${pkgs.netbird}/bin/netbird up --foreground-mode --hostname "$MESH_NAME" --setup-key-file "$CREDENTIALS_DIRECTORY/auth-key" --allow-server-ssh
          ''} %i";
          NoNewPrivileges = true;
          #PrivateUsers=true;  # Needs to be root for network stuff, but can we grant these privs another way?
          PrivateNetwork = true;
          PrivateMounts = true;
          ProtectHome = true;
          PrivateDevices = true;
          # netbird does routing things?
          ProtectSystem = false;
          ProtectKernelTunables = false;
          ProtectControlGroups = false;
          # Places to keep things
          RuntimeDirectory = "netbird_%i";
          StateDirectory = "netbird_%i";
          ConfigurationDirectory = "netbird_%i";
          BindReadOnlyPaths = concatStringsSep " " [
            # required by netbird?
            "/etc/static:/etc/static"
            "/etc/os-release:/etc/os-release"
            # maybe not required along with static?
            "/etc/pki:/etc/pki"
            "/etc/ssl:/etc/ssl"
          ];
          BindPaths = concatStringsSep " " [
            # use netbird_%i instead of netbird for storage
            "/run/netbird_%i:/run/netbird"
            "/var/lib/netbird_%i:/var/lib/netbird"
            "/etc/netbird_%i:/etc/netbird"
            # network namespace (for resolv etc, and to further isolate)
            "/etc/netns/%i:/etc"
          ];
        };
      };

      "tailscale@" = {
        enable = true;
        partOf = ["%i.service"];
        bindsTo = ["netns@%i.service"];
        after = ["netns@%i.service"];
        unitConfig.JoinsNamespaceOf = "netns@%i.service";
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          LoadCredential = "auth-key:${cfg.authKeyFile}";
          ExecStart = "${writeDash "tailscale-up" ''
            set -x
            MESH_NAME=$(echo '${meshNameMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // $service')
            # ${pkgs.tailscale}/bin/tailscaled -state 'mem:' &
            ${pkgs.tailscale}/bin/tailscaled -statedir "$STATE_DIRECTORY" -socket "$RUNTIME_DIRECTORY/tailscaled.sock" &
            ${pkgs.tailscale}/bin/tailscale -socket "$RUNTIME_DIRECTORY/tailscaled.sock" up --ssh --accept-dns=true --hostname="$MESH_NAME" --authkey="file:$CREDENTIALS_DIRECTORY/auth-key"
          ''} %i";
          NoNewPrivileges = true;
          # PrivateUsers = true; # Needs to be root for network stuff, but can we grant these privs another way?
          PrivateNetwork = true;
          PrivateMounts = true;
          ProtectHome = true;
          PrivateDevices = false; #true
          # tailscale does routing things?
          ProtectSystem = false;
          ProtectKernelTunables = false;
          ProtectControlGroups = false;
          # Places to keep things
          RuntimeDirectory = "tailscale_%i";
          StateDirectory = "tailscale_%i";
          ConfigurationDirectory = "tailscale_%i";
          TemporaryFileSystem = /etc;
          BindReadOnlyPaths = concatStringsSep " " [
            # required by tailscale?
            "/etc/static:/etc/static"
            "/etc/os-release:/etc/os-release"
            # maybe not required along with static?
            "/etc/pki:/etc/pki"
            "/etc/ssl:/etc/ssl"
          ];
          BindPaths = concatStringsSep " " [
            # use tailscale_%i instead of netbird for storage
            "/run/tailscale_%i:/run/tailscale"
            "/var/lib/tailscale_%i:/var/lib/tailscale"
            "/etc/tailscale_%i:/etc/tailscale"
            # network namespace (for resolv etc, and to further isolate)
            "/etc/netns/%i/resolv.conf:/etc/resolv.conf"
          ];
          DeviceAllow = ["/dev/net/tun rw"];
          # Give only the needed capability
          CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_MODULE"];
          AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_SYS_MODULE"];
        };
      };
    };
  in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        boot.kernel.sysctl."net.ipv4.ip_forward" = true;
        systemd.sockets.netns-publisher = {
          description = "netns publisher socket";
          wantedBy = ["sockets.target"];
          socketConfig = {
            ListenStream = "/var/run/netns-publisher.sock";
            SocketMode = "0600";
            Accept = false;
          };
        };
        systemd.services = moduleServices // serviceOverrides;
      })
      # Overrides
      # paperless
      (lib.mkIf (cfg.enable && cfg.knownServiceOverrides.paperless.enable && config.services.paperless.enable) {
        systemd.services = {
          # TODO: cleanup
          "paperless-web" = {
            serviceConfig.PrivateNetwork = lib.mkForce true;
            unitConfig.JoinsNamespaceOf = lib.mkForce "netns@paperless-web.service";
          };
          "paperless-task-queue" = {
            serviceConfig.PrivateNetwork = lib.mkForce true;
            unitConfig.JoinsNamespaceOf = lib.mkForce "netns@paperless-web.service";
          };
        };
      })
    ];
}
