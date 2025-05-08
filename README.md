# meshSidecar

Mesh network sidecars for NixOS Services

## Overview

meshSidecar provides a flexible way to integrate mesh networking capabilities with NixOS services. It allows services to participate in mesh networks without requiring direct modification of the service itself.

## Features

- Seamless integration with existing NixOS services
- Support for multiple mesh networking protocols
- Minimal configuration required
- Automatic service discovery within the mesh

## Usage

Add meshSidecar to your NixOS configuration and then:

```nix
services.meshSidecar = {
  enable = true;
  provider = "tailscale";
  authKey = "tskey-auth-fake";
  outboundInterface = "wlp3s0";
  # Wrap existing NixOS/systemd services
  wrappedServices = ["grafana" "prometheus"];
};
```

## Current Status

⚠️ **Early Development** ⚠️

This project is in early development and is subject to significant changes:

- The module interface may and probably will change without notice during early development
- Not all mesh network types are fully implemented
- Limited testing has been performed
- Documentation is incomplete or nonexistent
- There are many TODOs throughout the codebase

## Contributing

Contributions are welcome! Please feel free to submit an issue or pull request.

## License

MIT

