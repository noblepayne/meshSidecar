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
    nixosModule = self.nixosModules.default;
    nixosModules.meshSidecar = self.nixosModules.default;
  };
}
