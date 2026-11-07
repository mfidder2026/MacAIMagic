# PARITY: wat WinAIMagic nog moet overnemen · what WinAIMagic still has to take over

Bron: MacAIMagic-branch `agent-features` (fase 1 van de agent-functies, plus de hulp).
Source: MacAIMagic branch `agent-features` (phase 1 of the agent features, plus the help).

Vink een onderdeel af als het op Windows af en getest is. Neem geen Mac-meetwaarden over als Windows-metingen.
Tick an item when it is done and tested on Windows. Never present Mac measurements as Windows ones.

**Windows: adapt.** De opzet blijft gelijk (schakelaars, rechten, plan → goedkeuring → uitvoeren → controle → ongedaan maken).
De commando's en de beheerdersroute zijn anders.
**Windows: adapt.** The design stays the same (switches, rights, plan → approval → run → check → undo).
The commands and the administrator route differ.

---

## 1. Schakelaars en rechten · Switches and rights

- [ ] Instellingen → tab **Systeembeheer** (geen Experimenteel meer), beide standaard **aan**: `skills`, `systemManagement`. Zijn ze uit, dan krijgt het model exact dezelfde tools en systeemprompt als nu.
      Settings → tab **System management** (no longer Experimental), both **on** by default. When off, the model gets exactly the same tools and system prompt as now.
- [ ] Rechten `rightSystemRead` (standaard *allow*) en `rightSystemChange` (standaard *ask*), met Toestaan / Eerst vragen / Weigeren, en dezelfde waarschuwing bij *allow*.
      Rights `rightSystemRead` (default *allow*) and `rightSystemChange` (default *ask*), with the same warning for *allow*.
- [ ] Een beheerdersplan vraagt **altijd**, ook na "Altijd in dit gesprek". De knop "Altijd" staat niet op een beheerderskaart.
      An administrator plan **always** asks, even after "Always in this conversation". The "Always" button is not on an administrator card.

Mac: `Support/Settings.swift`, `Views/SettingsView.swift`, `Chat/ChatClient.swift` (`ask`, `runSystem`).

## 2. Skills

- [ ] Hetzelfde formaat: `skills/<naam>/SKILL.md` met front matter `name`, `description`, `platform` (`macos` | `windows` | `all`). Eigen skills in `%APPDATA%\WinAIMagic\Skills`; een eigen skill met dezelfde naam gaat voor.
      Same format, same front matter. Own skills in `%APPDATA%\WinAIMagic\Skills`; your own skill with the same name wins.
- [ ] Alleen naam + beschrijving in de systeemprompt, gesorteerd (zodat de KV-cache herbruikbaar blijft). De tool `use_skill(name)` geeft de tekst.
      Only name + description in the system prompt, sorted (so the KV cache stays reusable). The tool `use_skill(name)` returns the text.
- [ ] Schrijf de **Windows-varianten** met dezelfde namen en `platform: windows`, met commando's die op Windows 11 getest zijn:
      Write the **Windows variants** with the same names and `platform: windows`, with commands tested on Windows 11:

| Skill | Mac | Windows-tegenhanger · counterpart |
|---|---|---|
| uiterlijk | `defaults` (Dock, Finder), osascript voor donkere modus | `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` (`AppsUseLightTheme`, `SystemUsesLightTheme`), `...\Explorer\Advanced` (`TaskbarAl`, `HideFileExt`, `Hidden`), daarna explorer herstarten · then restart explorer |
| energie | `pmset` | `powercfg /query`, `powercfg /change monitor-timeout-ac 30`, `powercfg /batteryreport` |
| netwerk | `networksetup`, `scutil --dns` | `Get-NetAdapter`, `Get-DnsClientServerAddress`, `Set-DnsClientServerAddress` (admin), `ipconfig /flushdns` |
| software | `brew` | `winget list`, `winget upgrade`, `winget install --id <id> -e` |
| opstartitems | `launchctl`, inlogitems | `Get-CimInstance Win32_StartupCommand`, `HKCU\...\Run`, `Get-ScheduledTask`, `Get-Service` / `Set-Service -StartupType` (admin) |
| opslag | `df`, `du`, Finder-prullenmand | `Get-PSDrive`, `Get-ChildItem -Recurse \| Measure-Object`, naar de Prullenbak via `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(..., SendToRecycleBin)`, `cleanmgr` |
| privacy-beveiliging | `socketfilterfw`, `spctl`, `fdesetup`, `csrutil` | `Get-NetFirewallProfile` / `Set-NetFirewallProfile` (admin), `Get-MpComputerStatus` (Defender), `manage-bde -status` (BitLocker), UAC: `HKLM\...\Policies\System\EnableLUA` |
| diagnose | `top -l 1`, `vm_stat`, `pmset -g`, `log show` | `Get-Process \| Sort CPU -desc`, `Get-Counter`, `Get-CimInstance Win32_OperatingSystem`, `powercfg /energy`, `Get-WinEvent -LogName System -MaxEvents 50` |

Panelen die niet te scripten zijn · panes that cannot be scripted: `start ms-settings:privacy`, `ms-settings:windowsdefender`, `ms-settings:windowsupdate`.

## 3. Systeembeheer · System management

- [ ] **`system_read`**: één programma, alleen-lezen, zonder pipes / `;` / `&&` / omleiding / `$(...)`. Allowlist met PowerShell-cmdlets die met `Get-` beginnen (plus `Test-NetConnection`, `Resolve-DnsName`), `powercfg /query|/list|/batteryreport`, `ipconfig` (zonder `/release`, `/renew`), `winget list|show|search|upgrade` (zonder argumenten), `reg query`, `systeminfo`, `tasklist`, `netsh ... show`, `manage-bde -status`, `bcdedit /enum`. Weiger `Set-`, `Remove-`, `New-`, `Stop-`, `Invoke-Expression`, `iex`, `-EncodedCommand`, `|`, `;`, `` ` ``, `$(`.
      **`system_read`**: one program, read-only. Allowlist as above; reject everything that writes or chains.
      Mac: `SystemTools.isReadOnly` + `testReadOnlyAllowlist` (neem dezelfde testgevallen over, in hun Windows-vorm · take the same test cases over in their Windows form).
- [ ] **`system_change(summary, steps[])`**, met per stap `title`, `check`, `apply`, `undo`, `admin`. De kaart toont per stap de huidige waarde. Die waarde leest de app vooraf alleen als de check alleen-lezen is.
      Each step has title, check, apply, undo and admin. The card shows each step's current value, read beforehand only when the check is read-only.
- [ ] **Beheerder · administrator**: alle opeenvolgende admin-stappen samen in **één UAC-prompt**: `Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-File',<script>`. Het script schrijft per stap markeringen (`@@STEP i`, `@@EXIT $LASTEXITCODE`) naar een tijdelijk logbestand, omdat een verhoogd proces geen stdout teruggeeft aan de app. UAC geannuleerd = niets gewijzigd.
      All consecutive admin steps in **one UAC prompt**. The script writes markers to a temp log, since an elevated process does not give its stdout back. UAC cancelled = nothing changed.
      Mac: `SystemTools.runAdmin` (osascript `with administrator privileges`).
- [ ] **Vangnet · safety net**: het vinkje "Maak eerst een herstelpunt" (standaard aan bij admin): `Checkpoint-Computer -Description "WinAIMagic" -RestorePointType MODIFY_SETTINGS`. Let op: Windows maakt maximaal één herstelpunt per 24 uur, tenzij `SystemRestorePointCreationFrequency` anders staat; zeg dat op de kaart.
      Checkbox "Make a restore point first" (on by default for admin). Windows makes at most one restore point per 24 h unless configured otherwise; say so on the card.
      Mac: `tmutil localsnapshot`.
- [ ] **Exacte kopie voor ongedaan maken · exact copy for undo**: exporteer vóór de wijziging elke registersleutel die een stap schrijft (`reg export <sleutel> <bestand> /y`, herken `reg add` en `Set-ItemProperty -Path HK...`). Bij ongedaan maken: verschilt de sleutel nog, dan `reg import`, en daarna explorer herstarten als een stap dat deed.
      Before the change, export every registry key a step writes. On undo, if the key still differs: `reg import`, then restart explorer if a step did.
      Mac: `defaults export` / `defaults import` + `killall`.
- [ ] **Waarschuwingen, geen blokkade · warnings, not blocks** (`SystemTools.sensitive`). Windows-patronen: `Set-NetFirewallProfile.*-Enabled\s+False`, `Set-MpPreference.*-Disable`, `manage-bde\s+-off`, `EnableLUA`, `net user`, `Add-LocalGroupMember`, `bcdedit`, `Remove-Item.*-Recurse` (niet via de Prullenbak), `shutdown`, `Restart-Computer`, `hosts`, `-Verb RunAs` in een apply (dubbele verhoging), `iwr ... | iex`. Neem de bestaande teksten over en voeg een tekst toe voor Defender en UAC. Ook hier: een plan na het lezen van het web, en een stap zonder ongedaanmaking.
      Windows patterns as listed; reuse the existing texts and add ones for Defender and UAC. Also: a plan after reading the web, and a step without undo.
- [ ] **Wijzigingslog · change log**: `%APPDATA%\WinAIMagic\Changes\<id>\plan.json`, met hetzelfde JSON-formaat als de Mac (`id`, `date`, `summary`, `steps`, `results` [`before`, `after`, `output`, `ok`, `ran`], `exports`, `snapshot`, `undone`, `undoReport`).
      Same JSON format as the Mac.
- [ ] **Ongedaan maken · undo**: alleen via het model, met de tool `system_undo(id)` en dezelfde kaart (de laatste stap eerst). Er is geen lijst met wijzigingen in de app: die is op verzoek van de eigenaar weggehaald. Daarna elke check opnieuw uitvoeren en vergelijken met de waarde van vóór de wijziging.
      Only through the model, with the tool `system_undo(id)` and the same card (last step first). There is no list of changes in the app: the owner asked for it to be removed. Then run every check again and compare it with its value from before.
- [ ] Een stap die mislukt, stopt het plan; de stappen daarna blijven "niet uitgevoerd" · a failing step stops the plan; later steps stay "not run".
- [ ] Systeemtools tellen niet mee voor wat het model leert in WINAIMAGIC.md · system tools do not count for what the model learns.

Mac-tests om in Windows-vorm over te nemen · Mac tests to take over in Windows form: `SystemToolsTests` (allowlist, warnings, plan parsing, domains, a real change and undo on `HKCU\Software\WinAIMagicTest` with a wrong undo command, failing step).

## 4. Hulp · Help

- [ ] Een pagina **Hulp** in de zijbalk, een **?** in de werkbalk (de hulp bij het scherm dat open is), F1 / het Help-menu, en een ?-knop in de tab Systeembeheer.
      Sidebar page **Help**, a **?** in the toolbar (help for the page on screen), F1 / Help menu, and a ? in the System management tab.
- [ ] De inhoud staat in `help/nl/*.md` en `help/en/*.md`, één bestand per onderwerp, met front matter `title`, `icon`, `keywords`. Nederlands voor nl, Engels voor de andere talen.
      Content in `help/nl/*.md` and `help/en/*.md`, one file per topic. Dutch for nl, English for the other languages.
- [ ] **Neem de onderwerpen over en pas ze aan voor Windows**: VRAM + RAM + SSD in *Modellen* en *Live*, UAC en een herstelpunt in *Systeembeheer*, `%APPDATA%`-paden, de sneltoetsen (Ctrl in plaats van ⌘), de twee engines, en geen Time Machine of Thunderbolt Bridge.
      **Take the topics over and adapt them for Windows**: VRAM + RAM + SSD in *Models* and *Live*, UAC and a restore point in *System management*, `%APPDATA%` paths, shortcuts (Ctrl instead of ⌘), the two engines, and no Time Machine or Thunderbolt Bridge.
- [ ] Zoeken met een score: woord in de titel > in de trefwoorden > hoe vaak het in de tekst staat · search with a score: word in the title > in the keywords > how often in the text.
- [ ] Test: beide talen hebben dezelfde onderwerpen, elk scherm heeft zijn onderwerp, en zoeken werkt (`HelpTests`).
      Test: both languages have the same topics, every page has its topic, search works.

## 5. Vertalingen · Translations

- [ ] De nieuwe teksten zijn Nederlands (de sleutel) en Engels. Duits en Frans hebben voorlopig de Engelse tekst; vertaal ze als de eigenaar dat wil.
      The new texts are Dutch (the key) and English. German and French have the English text for now; translate them when the owner wants that.

## 6. Connectors (MCP), fase 2 · Connectors (MCP), phase 2

- [ ] **Configuratie · configuration**: `%APPDATA%\WinAIMagic\mcp.json`, hetzelfde formaat als op de Mac en in Claude Desktop (`mcpServers: {naam: {command, args, env} | {url, headers}}`), plus `enabled`, `right`, `alwaysLoaded`, `description`, `builtin`, `oauth`. Waarden `keychain:<naam>` komen uit de Windows Credential Manager. **Importeer** uit `%APPDATA%\Claude\claude_desktop_config.json` en `%USERPROFILE%\.claude.json`, uitgeschakeld.
      Same format as the Mac and Claude Desktop; `keychain:<name>` values come from the Windows Credential Manager; import from Claude Desktop and Claude Code, switched off.
- [ ] **Stdio**: start via `cmd /c` (zodat `npx.cmd` en `uvx.exe` gevonden worden), JSON per regel, stderr naar een log per connector, en antwoord op een `ping` van de server. Regels die geen JSON-RPC zijn, gaan naar het log.
      Start through `cmd /c`, one JSON message per line, stderr to a log, answer the server's ping; non-JSON-RPC lines go to the log.
- [ ] **Streamable HTTP**: POST met `Accept: application/json, text/event-stream`; lees JSON of SSE; `Mcp-Session-Id`; een DELETE bij afsluiten.
      POST, read JSON or SSE, keep the session id, DELETE on close.
- [ ] **OAuth**: 401 → `resource_metadata` → protected-resource metadata → `/.well-known/oauth-authorization-server` (met het pad erachter en zonder) → dynamische registratie (`token_endpoint_auth_method: none`, redirect `http://127.0.0.1:<poort>/callback`) → PKCE S256 in de standaardbrowser → callback-listener → token (met `resource`) in de Credential Manager → verversen. Neem de nep-server `App/Tests/MacAIMagicTests/Fixtures/fake_mcp_http.py` over voor de test van begin tot eind.
      Same flow; reuse the fake server fixture for the end-to-end test.
- [ ] **Laden op verzoek · on demand**: tool `use_connector(name)`; geladen connectors per gesprek bewaren (`connectors`), na een herstart weer starten; toolnamen `<connector>__<tool>`, alleen `[A-Za-z0-9_-]`, maximaal 64 tekens.
      Tool use_connector; loaded connectors kept per conversation and restarted; tool names as on the Mac.
- [ ] **Rechten · rights** (`MCPManager.decision`): Weigeren wint; `readOnlyHint` zonder `destructiveHint` mag; verder volgens het recht. Na het lezen van het web vraagt ook "Toestaan" eerst. Kaart met de argumenten als JSON (zonder `\/`) en waarschuwingen voor destructief, internet en web.
      Deny wins; read-only (not destructive) runs; else the right; after reading the web even Allow asks; card with JSON arguments and warnings.
- [ ] **Voorbeelden · examples**: Bestanden (`npx -y @modelcontextprotocol/server-filesystem` met Documenten, Downloads, Bureaublad), Web ophalen (`uvx mcp-server-fetch`), GitHub (`https://api.githubcopilot.com/mcp/`, token in de Credential Manager, `oauth: false`).
- [ ] **Agenda en Herinneringen**: op de Mac ingebouwd met EventKit (`CalendarConnector`, tools `list_events`, `create_event`, `list_reminders`, `create_reminder`, `complete_reminder`). Windows heeft geen EventKit: gebruik Microsoft Graph (Outlook-agenda en To Do) met OAuth, of laat dit voorbeeld weg en zeg dat in de lijst.
      Windows has no EventKit: use Microsoft Graph (Outlook calendar and To Do) with OAuth, or leave this example out and say so.
- [ ] **Scherm · screen**: tab Connectors (schakelaar, status, rechten, Test, Bewerken, Log, Uitloggen, Verwijderen; Voorbeeld toevoegen, Toevoegen, Importeer). Hulp-onderwerp `19-connectors.md` (NL/EN), aangepast voor Windows-paden en `cmd`.
- [ ] Tests: neem `MCPTests.swift` over (stdio-nep-server, HTTP met SSE, OAuth van begin tot eind, naamregels, rechten, mcp.json heen en terug) en `ConnectorIntegrationTests` (een echt model leest een map zonder kaart en schrijft na een kaart).

## Later (fase 3–6) · Later (phases 3–6)

Nog niet gebouwd; elke fase krijgt een eigen plan en een eigen stuk in dit bestand.
Not built yet; each phase gets its own plan and its own part of this file.

| Fase | Functie · feature | Schakelaar · switch |
|---|---|---|
| 3 | Takenlijst, achtergrond, heartbeat en cron · task list, background, heartbeat and cron | `featureTasks`, `featureHeartbeat` |
| 4 | Telegram, daarna iMessage (alleen Mac) · Telegram, then iMessage (Mac only) | `featureTelegram` |
| 5 | Browser-agent en e-mail · browser agent and mail | `featureBrowser`, `featureMail` |
| 6 | Computer besturen en spraak · computer use and voice | `featureComputerUse`, `featureVoice` |
