# minecraft/ - your server's settings

Edit or add files here and push. The "Sync Minecraft server" workflow copies them to the VM and restarts the server.

Common:
- `settings.env`  - edition (bedrock / java / java-geyser), versions, ports, keepalive, EULA
- `world.zip` or `*.mcworld` - a world to import (imported once; the old world is backed up first)

Bedrock edition:
- `server.properties`, `allowlist.json`, `permissions.json`
- `resource_packs/`, `behavior_packs/` - drop `.mcpack` / `.zip` files or pack folders

Java editions (java, java-geyser):
- `java.server.properties` - game settings
- `plugins/` - drop extra plugin `.jar` files (Paper plugins)
- Resource/behavior packs here are for Bedrock only.

Files over 100 MB can't be pushed to GitHub - upload large worlds to the VM with scp instead.
