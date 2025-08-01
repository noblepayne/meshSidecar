{
  config,
  options,
  pkgs,
  lib,
  ...
}: {
  options.services.meshSidecar = {
    enable = lib.mkEnableOption "meshSidecar module";

    # TODO: validate in allowed set of known providers
    provider = lib.mkOption {
      type = lib.types.str;
      description = ''Mesh network service provider e.g. currently "tailscale" or "netbird".'';
      default = "tailscale";
    };

    # TODO: support providing multiple, tied to service. support multiple mesh providers at once?
    # TODO: authKeyFile to avoid baking keys into scripts or service configs
    authKey = lib.mkOption {
      type = lib.types.str;
      description = "Authentication key string.";
    };

    outboundInterface = lib.mkOption {
      type = lib.types.str;
      description = "Name of the outbound network interface.";
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the bridge interface.";
      default = "br0";
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

    # TODO: switch to attrset interface for config options
    wrappedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "List of systemd service names to wrap.";
      default = [];
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
    serviceOverrides = lib.genAttrs cfg.wrappedServices (svc: {
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
    });
    moduleServices = {
      "systemdbridge" = {
        before = ["network.target"];
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          PrivateMounts = true;
          ProtectSystem = "strict";
          RuntimeDirectory = "systemdbridge";
          # TODO: document why this is needed
          BindPaths = "/run/systemdbridge:/var/lib/misc";
          ExecStop = "${ip} link del br0";
          # TODO: configurable outbound interface or autodiscovery?
          ExecStart = "${
            writeDash "${cfg.bridgeName}-up" ''
              set -x
              # TODO: export needed?
              export PATH=${pkgs.busybox}/bin
              ${ip} link add br0 type bridge
              ${ip} addr add ${cfg.bridgeCidr} dev ${cfg.bridgeName}
              ${ip} link set ${cfg.bridgeName} up
              ${iptables} -t nat -A POSTROUTING -o ${cfg.outboundInterface} -j MASQUERADE
              ${iptables} -A FORWARD -i ${cfg.bridgeName} -o ${cfg.outboundInterface} -j ACCEPT
              ${iptables} -A FORWARD -i ${cfg.outboundInterface} -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
              #${udhcpd} -f ${writeText "udhcpd-cfg" "interface br0\nstart 192.168.222.3\nend 192.168.222.103\noption router 192.168.222.2\noption dns 1.1.1.1\n"}
              ${udhcpd} -f ${writeText "udhcpd-cfg" "interface ${cfg.bridgeName}\nstart ${dhcpStart}\nend ${dhcpEnd}\noption router ${dhcpRouter}\n"}
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

      "netns@" = {
        description = "%i network namespace";
        partOf = ["netbird@%i.service" "tailscale@%i.service"];
        bindsTo = ["systemdbridge.service" "defaultnetns.service"];
        after = ["defaultnetns.service"];
        before = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateNetwork = true;
          ConfigurationDirectory = "netns/%i";
          PrivateMounts = false; # TODO...
          ExecStart = "${
            writeDash "netns-up" (''
                set -x
                ${ip} netns add $1
                ${umount} /var/run/netns/$1
                ${mount} --bind /proc/self/ns/net /var/run/netns/$1
                ${ip} link add $1 type veth peer name eth0
                ${ip} link set eth0 up
                ${ip} link set netns default dev $1
                ${ip} netns exec default ${ip} link set $1 master br0
                ${ip} netns exec default ${ip} link set br0 up
                ${ip} netns exec default ${ip} link set $1 up

                #${ip} netns exec default cat /etc/nsswitch.conf > /etc/netns/$1/nsswitch.conf
                #echo 'hosts: dns' > /etc/netns/$1/nsswitch.conf

                touch /etc/netns/$1/resolv.conf
                ${ip} netns exec $1 ${udhcpc} -q -i eth0
                # TODO: patch udhcpc to only overwrite when dns option is present
                # until then, we just overwrite after it runs
                # TODO: needs magic dns if we want tailscale to manage, if non-empty.
                # leaving empty for now as this does not break tailscale
                #${ip} netns exec default cat /etc/resolv.conf > /etc/netns/$1/resolv.conf
                #cat /etc/netns/$1/resolv.conf
              ''
              + (
                if cfg.provider == "netbird"
                then "\n${ip} netns exec default cat /etc/resolv.conf > /etc/netns/$1/resolv.conf\n"
                else ""
              ))
          } %i";
          ExecStop = "${
            writeDash "netns-down" ''
              ${ip} netns exec default ${ip} link del $1
              ${ip} netns del $1
              rm -rf /etc/netns/$1
            ''
          } %i";
          # TODO: delete veths?
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
          ExecStart = "${writeDash "netbird-up" ''
            set -x
            ${pkgs.netbird}/bin/netbird up -F -n $1 -k ${cfg.authKey} --allow-server-ssh
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
          ExecStart = "${writeDash "tailscale-up" ''
            set -x
            # ${pkgs.tailscale}/bin/tailscaled -state 'mem:' &
            ${pkgs.tailscale}/bin/tailscaled -statedir "$STATE_DIRECTORY" -socket "$RUNTIME_DIRECTORY/tailscaled.sock" &
            ${pkgs.tailscale}/bin/tailscale -socket "$RUNTIME_DIRECTORY/tailscaled.sock" up --ssh --accept-dns=true --hostname=$1 --authkey="${cfg.authKey}"
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
    lib.mkIf cfg.enable {
      systemd.services = moduleServices // serviceOverrides;
    };
}
