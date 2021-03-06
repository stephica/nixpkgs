# Extend a derivation with checks for brokenness, license, etc.  Throw a
# descriptive error when the check fails; return `derivationArg` otherwise.
# Note: no dependencies are checked in this step.

{ lib, config, system, meta, derivationArg, mkDerivationArg }:

let
  attrs = mkDerivationArg; # TODO: probably get rid of passing this one

  # See discussion at https://github.com/NixOS/nixpkgs/pull/25304#issuecomment-298385426
  # for why this defaults to false, but I (@copumpkin) want to default it to true soon.
  shouldCheckMeta = config.checkMeta or false;

  allowUnfree = config.allowUnfree or false || builtins.getEnv "NIXPKGS_ALLOW_UNFREE" == "1";

  whitelist = config.whitelistedLicenses or [];
  blacklist = config.blacklistedLicenses or [];

  onlyLicenses = list:
    lib.lists.all (license:
      let l = lib.licenses.${license.shortName or "BROKEN"} or false; in
      if license == l then true else
        throw ''‘${showLicense license}’ is not an attribute of lib.licenses''
    ) list;

  areLicenseListsValid =
    if lib.mutuallyExclusive whitelist blacklist then
      assert onlyLicenses whitelist; assert onlyLicenses blacklist; true
    else
      throw "whitelistedLicenses and blacklistedLicenses are not mutually exclusive.";

  hasLicense = attrs:
    attrs ? meta.license;

  hasWhitelistedLicense = assert areLicenseListsValid; attrs:
    hasLicense attrs && builtins.elem attrs.meta.license whitelist;

  hasBlacklistedLicense = assert areLicenseListsValid; attrs:
    hasLicense attrs && builtins.elem attrs.meta.license blacklist;

  allowBroken = config.allowBroken or false || builtins.getEnv "NIXPKGS_ALLOW_BROKEN" == "1";

  allowUnsupportedSystem = config.allowUnsupportedSystem or false;

  isUnfree = licenses: lib.lists.any (l:
    !l.free or true || l == "unfree" || l == "unfree-redistributable") licenses;

  # Alow granular checks to allow only some unfree packages
  # Example:
  # {pkgs, ...}:
  # {
  #   allowUnfree = false;
  #   allowUnfreePredicate = (x: pkgs.lib.hasPrefix "flashplayer-" x.name);
  # }
  allowUnfreePredicate = config.allowUnfreePredicate or (x: false);

  # Check whether unfree packages are allowed and if not, whether the
  # package has an unfree license and is not explicitely allowed by the
  # `allowUNfreePredicate` function.
  hasDeniedUnfreeLicense = attrs:
    !allowUnfree &&
    hasLicense attrs &&
    isUnfree (lib.lists.toList attrs.meta.license) &&
    !allowUnfreePredicate attrs;

  allowInsecureDefaultPredicate = x: builtins.elem x.name (config.permittedInsecurePackages or []);
  allowInsecurePredicate = x: (config.allowUnfreePredicate or allowInsecureDefaultPredicate) x;

  hasAllowedInsecure = attrs:
    (attrs.meta.knownVulnerabilities or []) == [] ||
    allowInsecurePredicate attrs ||
    builtins.getEnv "NIXPKGS_ALLOW_INSECURE" == "1";

  showLicense = license: license.shortName or "unknown";

  pos_str = meta.position or "«unknown-file»";

  remediation = {
    unfree = remediate_whitelist "Unfree";
    broken = remediate_whitelist "Broken";
    blacklisted = x: "";
    insecure = remediate_insecure;
    unknown-meta = x: "";
  };
  remediate_whitelist = allow_attr: attrs:
    ''
      a) For `nixos-rebuild` you can set
        { nixpkgs.config.allow${allow_attr} = true; }
      in configuration.nix to override this.

      b) For `nix-env`, `nix-build`, `nix-shell` or any other Nix command you can add
        { allow${allow_attr} = true; }
      to ~/.config/nixpkgs/config.nix.
    '';

  remediate_insecure = attrs:
    ''

      Known issues:

    '' + (lib.fold (issue: default: "${default} - ${issue}\n") "" attrs.meta.knownVulnerabilities) + ''

        You can install it anyway by whitelisting this package, using the
        following methods:

        a) for `nixos-rebuild` you can add ‘${attrs.name or "«name-missing»"}’ to
           `nixpkgs.config.permittedInsecurePackages` in the configuration.nix,
           like so:

             {
               nixpkgs.config.permittedInsecurePackages = [
                 "${attrs.name or "«name-missing»"}"
               ];
             }

        b) For `nix-env`, `nix-build`, `nix-shell` or any other Nix command you can add
        ‘${attrs.name or "«name-missing»"}’ to `permittedInsecurePackages` in
        ~/.config/nixpkgs/config.nix, like so:

             {
               permittedInsecurePackages = [
                 "${attrs.name or "«name-missing»"}"
               ];
             }

      '';

  throwEvalHelp = { reason , errormsg ? "" }:
    throw (''
      Package ‘${attrs.name or "«name-missing»"}’ in ${pos_str} ${errormsg}, refusing to evaluate.

      '' + ((builtins.getAttr reason remediation) attrs));

  metaTypes = with lib.types; rec {
    # These keys are documented
    description = str;
    longDescription = str;
    branch = str;
    homepage = either (listOf str) str;
    downloadPage = str;
    license = either (listOf lib.types.attrs) (either lib.types.attrs str);
    maintainers = listOf str;
    priority = int;
    platforms = listOf str;
    hydraPlatforms = listOf str;
    broken = bool;

    # Weirder stuff that doesn't appear in the documentation?
    version = str;
    tag = str;
    updateWalker = bool;
    executables = listOf str;
    outputsToInstall = listOf str;
    position = str;
    repositories = attrsOf str;
    isBuildPythonPackage = platforms;
    schedulingPriority = str;
    downloadURLRegexp = str;
    isFcitxEngine = bool;
    isIbusEngine = bool;
    isGutenprint = bool;
  };

  checkMetaAttr = k: v:
    if metaTypes?${k} then
      if metaTypes.${k}.check v then null else "key '${k}' has a value ${toString v} of an invalid type ${builtins.typeOf v}; expected ${metaTypes.${k}.description}"
    else "key '${k}' is unrecognized; expected one of: \n\t      [${lib.concatMapStringsSep ", " (x: "'${x}'") (lib.attrNames metaTypes)}]";
  checkMeta = meta: if shouldCheckMeta then lib.remove null (lib.mapAttrsToList checkMetaAttr meta) else [];

  # Check if a derivation is valid, that is whether it passes checks for
  # e.g brokenness or license.
  #
  # Return { valid: Bool } and additionally
  # { reason: String; errormsg: String } if it is not valid, where
  # reason is one of "unfree", "blacklisted" or "broken".
  checkValidity = attrs:
    if hasDeniedUnfreeLicense attrs && !(hasWhitelistedLicense attrs) then
      { valid = false; reason = "unfree"; errormsg = "has an unfree license (‘${showLicense attrs.meta.license}’)"; }
    else if hasBlacklistedLicense attrs then
      { valid = false; reason = "blacklisted"; errormsg = "has a blacklisted license (‘${showLicense attrs.meta.license}’)"; }
    else if !allowBroken && attrs.meta.broken or false then
      { valid = false; reason = "broken"; errormsg = "is marked as broken"; }
    else if !allowUnsupportedSystem && !allowBroken && attrs.meta.platforms or null != null && !lib.lists.elem system attrs.meta.platforms then
      { valid = false; reason = "broken"; errormsg = "is not supported on ‘${system}’"; }
    else if !(hasAllowedInsecure attrs) then
      { valid = false; reason = "insecure"; errormsg = "is marked as insecure"; }
    else let res = checkMeta (attrs.meta or {}); in if res != [] then
      { valid = false; reason = "unknown-meta"; errormsg = "has an invalid meta attrset:${lib.concatMapStrings (x: "\n\t - " + x) res}"; }
    else { valid = true; };

  # Throw an error if trying to evaluate an non-valid derivation
  validityCondition =
         let v = checkValidity attrs;
         in if !v.valid
           then throwEvalHelp (removeAttrs v ["valid"])
           else true;

in
  assert validityCondition;
  derivationArg
