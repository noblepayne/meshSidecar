{
  description = "Mesh network sidecars for NixOS Services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: {
    nixosModules.default = import ./meshSidecar.nix;
    nixosModules.meshSidecar = self.nixosModules.default;
  };
}
