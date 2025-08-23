# meshSidecar

Mesh network sidecars for NixOS Services

## Overview

meshSidecar provides a flexible way to integrate mesh networking capabilities with NixOS services. It allows services to participate in mesh networks without requiring direct modification of the service itself.

## Features

- Seamless integration with existing NixOS services
- Support for multiple mesh networking protocols (Tailscale, NetBird)
- Minimal configuration required
- Automatic service discovery within the mesh
- Custom mesh hostnames per service
- Secure credential handling via file-based authentication
- Optional service-specific overrides via `knownServiceOverrides`

## Usage

Add meshSidecar to your NixOS configuration:

- ⚠️ Note: Currently, users must explicitly list the systemd units to wrap. `knownServiceOverrides` provides a hook for service-specific tweaks (like Paperless), but does not automatically wrap all units in a stack.

```nix
services.meshSidecar = {
  enable = true;
  provider = "tailscale";  # or "netbird"
  authKeyFile = "/run/secrets/tailscale-key";
  outboundInterface = "wlp3s0";

  # Wrap existing NixOS/systemd services
  services = {
    grafana = {
      meshName = "monitoring-grafana";  # Custom hostname on mesh
    };
    prometheus = {};  # Uses service name "prometheus" as hostname
  };

  # Enable service-specific overrides
  knownServiceOverrides = {
    paperless.enable = true;
  };
};
```

## Current Status

⚠️ **Early Development** ⚠️

This project is in early development and is subject to significant changes:

- The module interface may and probably will change without notice
- Not all mesh network types are fully implemented
- Limited testing has been performed
- Documentation is incomplete or in progress
- Many TODOs remain in the codebase

## Contributing

Contributions are welcome! Please feel free to submit an issue or pull request.

## License

MIT

