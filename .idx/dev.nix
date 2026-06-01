{ pkgs, ... }: {
  channel = "stable-24.05";

  packages = [
    pkgs.nodejs_20
    pkgs.chromium
    pkgs.xorg.xvfb
    pkgs.coreutils
    pkgs.util-linux
  ];

  env = {
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";
    PMX_BROWSERLESS_MODE = "next-api";
    PMX_NEXT_SERVER_MODE = "start";
    PMX_NEXT_FORCE_BUILD = "1";
    PMX_REUSE_BROWSER = "0";
    PMX_FIREBASE_HEADFUL_XVFB = "1";
    PORT = "3000";
    CONCURRENT = "2";
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
