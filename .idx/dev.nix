{ pkgs, ... }: {
  channel = "stable-24.05";

  packages = [
    pkgs.nodejs_20
    pkgs.chromium
    pkgs.coreutils
    pkgs.util-linux
  ];

  env = {
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";
    PMX_BROWSERLESS_MODE = "next-api";
    PORT = "3000";
    CONCURRENT = "1";
    QUEUED = "20";
    TIMEOUT = "300000";
  };

  idx.previews = {
    enable = true;
    previews = {
      browserless = {
        command = [ "sh" "pmx-browserless-runtime/scripts/firebase-studio-start.sh" ];
        manager = "web";
        env = {
          PORT = "$PORT";
        };
      };
    };
  };
}
