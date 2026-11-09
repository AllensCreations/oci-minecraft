#!/usr/bin/env bash
# Runs ON THE VM as root. Safe to run repeatedly: installs on first run, syncs config afterwards.
set -euo pipefail
DEPLOY="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$DEPLOY/minecraft"
[ -f "$CFG/settings.env" ] && . "$CFG/settings.env"
EDITION="${EDITION:-bedrock}"
BEDROCK_VERSION="${BEDROCK_VERSION:-}"
PAPER_VERSION="${PAPER_VERSION:-}"
SERVER_PORT="${SERVER_PORT:-19132}"
JAVA_PORT="${JAVA_PORT:-25565}"
JAVA_RAM_MB="${JAVA_RAM_MB:-}"
EULA="${EULA:-false}"
KEEPALIVE="${KEEPALIVE:-yes}"
MC=/opt/minecraft
ARCH=$(uname -m)
log(){ echo "==> $*"; }
case "$EDITION" in bedrock|java|java-geyser) ;; *) echo "Unknown EDITION '$EDITION'"; exit 1;; esac
IS_JAVA=0; [ "$EDITION" != "bedrock" ] && IS_JAVA=1
if [ $IS_JAVA = 1 ] && [ "$EULA" != "true" ]; then
  echo "Java editions need EULA=true in minecraft/settings.env (accepts https://aka.ms/MinecraftEULA)"; exit 1
fi

cloud-init status --wait >/dev/null 2>&1 || true

log "Installing packages"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  APT="apt-get -o DPkg::Lock::Timeout=300 -y -q"
  $APT update
  $APT install curl unzip jq gnupg ca-certificates iptables-persistent
  if [ $IS_JAVA = 0 ]; then $APT install libcurl4 openssl; fi
else
  dnf install -y curl unzip jq
  if [ $IS_JAVA = 0 ]; then dnf install -y libcurl openssl; fi
fi


JAVA_BIN=""
jmajor(){ "$1" -version 2>&1 | awk -F'[".]' '/version/ {print $2; exit}'; }
install_java(){
  local want="$1" cand cur A
  for cand in $(ls /usr/lib/jvm/*/bin/java /opt/java*/bin/java 2>/dev/null) "$(command -v java || true)"; do
    [ -x "$cand" ] || continue
    cur=$(jmajor "$cand" 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" -ge "$want" ] 2>/dev/null; then JAVA_BIN="$cand"; return 0; fi
  done
  log "Installing Java $want"
  if command -v apt-get >/dev/null; then $APT install "openjdk-${want}-jre-headless" || true
  else dnf install -y "java-${want}-openjdk-headless" || true; fi
  for cand in $(ls /usr/lib/jvm/*/bin/java 2>/dev/null); do
    cur=$(jmajor "$cand" 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" -ge "$want" ] 2>/dev/null; then JAVA_BIN="$cand"; return 0; fi
  done
  log "Package not available - downloading Eclipse Temurin $want"
  case "$ARCH" in aarch64) A=aarch64 ;; x86_64) A=x64 ;; *) echo "Unsupported CPU $ARCH"; exit 1 ;; esac
  mkdir -p "/opt/java$want"
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/${want}/ga/linux/${A}/jre/hotspot/normal/eclipse" -o /tmp/jre.tgz
  tar xzf /tmp/jre.tgz -C "/opt/java$want" --strip-components=1
  rm -f /tmp/jre.tgz
  JAVA_BIN="/opt/java$want/bin/java"
  [ -x "$JAVA_BIN" ] || { echo "Java $want install failed"; exit 1; }
}

id minecraft >/dev/null 2>&1 || useradd -r -m -d "$MC" -s /usr/sbin/nologin minecraft
mkdir -p "$MC"

############ edition install
if [ $IS_JAVA = 0 ]; then
  if [ "$ARCH" = "aarch64" ] && ! command -v box64 >/dev/null; then
    log "ARM CPU detected: installing box64 to run the x86 Bedrock server"
    if command -v apt-get >/dev/null; then
      curl -fsSL https://ryanfortner.github.io/box64-debs/box64.list -o /etc/apt/sources.list.d/box64.list || true
      curl -fsSL https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor --yes -o /usr/share/keyrings/box64-debs-archive-keyring.gpg || true
      $APT update || true
      $APT install box64-generic-arm || true
    fi
    if ! command -v box64 >/dev/null; then
      log "Building box64 from source (takes a few minutes)"
      if command -v apt-get >/dev/null; then $APT install git cmake build-essential python3
      else dnf install -y git cmake gcc gcc-c++ make python3; fi
      rm -rf /tmp/box64 && git clone --depth 1 https://github.com/ptitSeb/box64 /tmp/box64
      cmake -S /tmp/box64 -B /tmp/box64/build -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
      make -C /tmp/box64/build -j"$(nproc)"
      make -C /tmp/box64/build install
    fi
  fi
  log "Checking Bedrock server version"
  if [ -n "$BEDROCK_VERSION" ]; then
    URL="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${BEDROCK_VERSION}.zip"
  else
    URL=$(curl -fsSL -A "Mozilla/5.0" https://net-secondary.web.minecraft-services.net/api/v1.0/download/links \
      | jq -r '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl')
  fi
  [ -n "$URL" ] || { echo "Could not find the Bedrock download URL. Set BEDROCK_VERSION in minecraft/settings.env"; exit 1; }
  VER=$(basename "$URL" .zip)
  if [ "$(cat "$MC/.version" 2>/dev/null || true)" != "$VER" ]; then
    log "Downloading $VER"
    curl -fsSL -A "Mozilla/5.0" "$URL" -o /tmp/bedrock.zip
    unzip -oq /tmp/bedrock.zip -x 'worlds/*' server.properties allowlist.json permissions.json -d "$MC"
    chmod +x "$MC/bedrock_server"
    echo "$VER" > "$MC/.version"
    rm -f /tmp/bedrock.zip
  fi
  for f in server.properties allowlist.json permissions.json; do
    [ -f "$CFG/$f" ] && cp "$CFG/$f" "$MC/$f"
  done
else
  log "Checking Paper (Java) version"
  V="$PAPER_VERSION"
  [ -z "$V" ] && V="$(cat "$MC/.paper_version" 2>/dev/null || true)"
  if [ -z "$V" ]; then
    V=$(curl -fsSL https://fill.papermc.io/v3/projects/paper | jq -r '[.versions | to_entries[] | .value[]] | .[0] // empty' 2>/dev/null || true)
    [ -z "$V" ] && V=$(curl -fsSL https://api.papermc.io/v2/projects/paper | jq -r '.versions[-1] // empty' 2>/dev/null || true)
  fi
  [ -n "$V" ] || { echo "Could not determine Paper version. Set PAPER_VERSION in minecraft/settings.env"; exit 1; }
  case "$V" in 1.*) JMAJOR=21 ;; *) JMAJOR=25 ;; esac   # Minecraft 26.x needs Java 25; 1.21.x needs 21
  install_java "$JMAJOR"
  URL=$(curl -fsSL "https://fill.papermc.io/v3/projects/paper/versions/$V/builds/latest" | jq -r '.downloads["server:default"].url // empty' 2>/dev/null || true)
  if [ -z "$URL" ]; then
    B=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/$V/builds" | jq -r '.builds[-1].build // empty' 2>/dev/null || true)
    [ -n "$B" ] && URL="https://api.papermc.io/v2/projects/paper/versions/$V/builds/$B/downloads/paper-$V-$B.jar"
  fi
  [ -n "$URL" ] || { echo "Could not find a Paper download for $V"; exit 1; }
  if [ "$(cat "$MC/.paper_url" 2>/dev/null || true)" != "$URL" ]; then
    log "Downloading Paper $V"
    curl -fsSL "$URL" -o "$MC/paper.jar"
    echo "$URL" > "$MC/.paper_url"; echo "$V" > "$MC/.paper_version"
  fi
  echo "eula=true" > "$MC/eula.txt"
  mkdir -p "$MC/plugins"
  if [ "$EDITION" = "java-geyser" ]; then
    log "Updating Geyser + Floodgate"
    curl -fsSL -o "$MC/plugins/Geyser-Spigot.jar" https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
    curl -fsSL -o "$MC/plugins/floodgate-spigot.jar" https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
  fi
  ls "$CFG"/plugins/*.jar >/dev/null 2>&1 && cp "$CFG"/plugins/*.jar "$MC/plugins/"
  if [ -f "$CFG/java.server.properties" ]; then
    cp "$CFG/java.server.properties" "$MC/server.properties"
    sed -i '/^server-port=/d' "$MC/server.properties"; echo "server-port=$JAVA_PORT" >> "$MC/server.properties"
  fi
fi

############ world + packs
log "Syncing config"
LEVEL=$(grep '^level-name=' "$MC/server.properties" 2>/dev/null | head -1 | cut -d= -f2- || true)
if [ $IS_JAVA = 1 ]; then LEVEL="${LEVEL:-world}"; WORLD_DIR="$MC/$LEVEL"; else LEVEL="${LEVEL:-Bedrock level}"; WORLD_DIR="$MC/worlds/$LEVEL"; fi

WZ=$(ls "$CFG"/world.zip "$CFG"/*.mcworld 2>/dev/null | head -1 || true)
if [ -n "$WZ" ]; then
  H=$(sha256sum "$WZ" | cut -d' ' -f1)
  if [ "$H" != "$(cat "$MC/.world_sha" 2>/dev/null || true)" ]; then
    log "Importing world"
    systemctl stop minecraft 2>/dev/null || true
    mkdir -p "$MC/backups"
    if [ -d "$WORLD_DIR" ]; then
      tar czf "$MC/backups/before-import-$(date +%F-%H%M).tgz" -C "$(dirname "$WORLD_DIR")" "$(basename "$WORLD_DIR")" || true
    fi
    T=$(mktemp -d); unzip -oq "$WZ" -d "$T"
    L=$(find "$T" -name level.dat | head -1 || true)
    if [ -n "$L" ]; then
      rm -rf "$WORLD_DIR"; mkdir -p "$WORLD_DIR"
      cp -r "$(dirname "$L")/." "$WORLD_DIR/"
      echo "$H" > "$MC/.world_sha"
    else
      echo "WARNING: world zip has no level.dat, skipped"
    fi
    rm -rf "$T"
  fi
fi
mkdir -p "$WORLD_DIR"

build_packs(){
  local kind="$1" src="$CFG/${1}_packs" dst="$MC/${1}_packs" entries='[]' m d id ver f
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  for f in "$src"/*.mcpack "$src"/*.zip "$src"/*.mcaddon; do
    [ -f "$f" ] || continue
    d="${f%.*}"; mkdir -p "$d"; unzip -oq "$f" -d "$d"; rm -f "$f"
  done
  while IFS= read -r m; do
    d=$(dirname "$m")
    id=$(jq -r '.header.uuid // empty' "$m"); ver=$(jq -c '.header.version // empty' "$m")
    [ -n "$id" ] && [ -n "$ver" ] || continue
    rm -rf "$dst/$(basename "$d")"; cp -r "$d" "$dst/$(basename "$d")"
    entries=$(echo "$entries" | jq -c --arg id "$id" --argjson v "$ver" '. + [{"pack_id":$id,"version":$v}]')
  done < <(find "$src" -name manifest.json)
  if [ "$entries" != '[]' ]; then echo "$entries" > "$WORLD_DIR/world_${kind}_packs.json"; log "Enabled $kind packs: $entries"; fi
}
if [ $IS_JAVA = 0 ]; then build_packs resource; build_packs behavior; fi

chown -R minecraft:minecraft "$MC"

############ firewall
open_fw(){
  local port="$1" proto="$2"
  if command -v firewall-cmd >/dev/null && systemctl is-active -q firewalld; then
    firewall-cmd --permanent --add-port="${port}/${proto}" && firewall-cmd --reload
  else
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    command -v netfilter-persistent >/dev/null && netfilter-persistent save || true
  fi
}
log "Firewall"
case "$EDITION" in
  bedrock) open_fw "$SERVER_PORT" udp ;;
  java) open_fw "$JAVA_PORT" tcp ;;
  java-geyser) open_fw "$JAVA_PORT" tcp; open_fw "$SERVER_PORT" udp ;;
esac

############ service
log "Service"
if [ $IS_JAVA = 1 ]; then
  if [ -z "$JAVA_RAM_MB" ]; then
    TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    JAVA_RAM_MB=$(( TOTAL * 60 / 100 ))
  fi
  EXEC="$JAVA_BIN -Xms${JAVA_RAM_MB}M -Xmx${JAVA_RAM_MB}M -jar $MC/paper.jar --nogui"
  ENVLINE="Environment=LANG=C.UTF-8"
  BACKUP_PATHS="${LEVEL}*"
else
  BOX=""; [ "$ARCH" = "aarch64" ] && BOX="$(command -v box64) "
  EXEC="${BOX}$MC/bedrock_server"
  ENVLINE="Environment=LD_LIBRARY_PATH=."
  BACKUP_PATHS="worlds"
fi
cat > /etc/systemd/system/minecraft.service <<UNIT
[Unit]
Description=Minecraft Server ($EDITION)
After=network.target

[Service]
User=minecraft
WorkingDirectory=$MC
$ENVLINE
Environment=BOX64_LOG=0
ExecStart=$EXEC
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/local/bin/mc-backup <<B
#!/bin/sh
mkdir -p $MC/backups
cd $MC && tar czf $MC/backups/world-\$(date +%F).tgz $BACKUP_PATHS
ls -t $MC/backups/world-*.tgz | tail -n +6 | xargs -r rm -f
B
chmod +x /usr/local/bin/mc-backup
echo '0 4 * * * root /usr/local/bin/mc-backup' > /etc/cron.d/mc-backup

if [ "$KEEPALIVE" = "yes" ]; then
  log "Keepalive (prevents Oracle idle reclamation)"
  if command -v apt-get >/dev/null; then $APT install stress-ng || true; else dnf install -y stress-ng || true; fi
  if command -v stress-ng >/dev/null; then
    cat > /etc/systemd/system/keepalive.service <<UNIT
[Unit]
Description=Oracle idle-reclaim keepalive
After=network.target

[Service]
ExecStart=$(command -v stress-ng) --cpu $(nproc) --cpu-load 25 --timeout 0
Nice=19
CPUSchedulingPolicy=idle
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable --now keepalive
  fi
else
  systemctl disable --now keepalive 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable minecraft
systemctl restart minecraft

# Geyser: let Bedrock players join without a Java account (Floodgate)
if [ "$EDITION" = "java-geyser" ]; then
  G="$MC/plugins/Geyser-Spigot/config.yml"
  for i in $(seq 1 36); do [ -f "$G" ] && break; sleep 5; done
  if [ -f "$G" ] && ! grep -q 'auth-type: floodgate' "$G"; then
    sed -i 's/^\([[:space:]]*\)auth-type:.*/\1auth-type: floodgate/' "$G"
    systemctl restart minecraft
  fi
fi

sleep 25
if systemctl is-active -q minecraft; then
  log "Minecraft server ($EDITION) is running"
else
  journalctl -u minecraft -n 40 --no-pager || true
  echo "Server failed to start - see log above."; exit 1
fi
