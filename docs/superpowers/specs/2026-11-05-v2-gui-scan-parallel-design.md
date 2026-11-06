# Plano — Cisco C9200 OT Collector v2: GUI, presets em JSON, varredura /24 e coleta paralela

## Contexto

**Por quê.** O repositório `marceloasl99/cisco-c9200-ot-investigation-collector` tem 1 script PowerShell (478 linhas) que coleta comandos `show` de switches Catalyst 9200 via `plink`, **um switch por vez**. A configuração fica fixa no próprio script e os logs se limitam a `show logging | last 300`. O objetivo é transformá-lo numa ferramenta operável por um técnico em campo, com:
- GUI no Windows 11/Server, presets e acompanhamento do andamento;
- varredura de sub-rede antes de conectar;
- coleta paralela;
- logs por período.

**Problemas encontrados no código atual (verificados localmente):**
1. **O script não roda no Windows PowerShell 5.1 com plink 0.84.**
   - O `& plink -h 2>&1`, com `$ErrorActionPreference='Stop'`, gera exceção, porque o plink 0.84 não aceita mais `-h` e responde `unknown option "-h"`. O script morre com `FATAL` antes de pedir a senha.
   - No pwsh 7 não há exceção, mas `SupportsPwFile=False`. A senha então vai via `-pw` e fica visível na linha de comando do processo.
2. `show logging | last 300`: o suporte do modificador `| last` no IOS-XE do C9200 não está confirmado. Em vários Catalyst ele não existe, e aí o relatório sai sem logs.
3. A função `Invoke-SwitchCollection` sobrescreve a variável automática `$args`.

**Decisões confirmadas pelo usuário**

| Tema | Decisão |
|---|---|
| Interface | **GUI Windows** (Win 11 / Server com Desktop Experience) com todas as opções e acompanhamento passo a passo; o CLI continua para uso headless |
| Configuração | **JSON padrão** com presets, que também salva as escolhas do operador (senha nunca é salva) |
| Logs | **Fonte e período escolhidos na execução**: buffer (`show logging`) e/ou histórico de reboots (OBFL); 3/7/30/90 dias, tudo ou N personalizado |
| Host keys novas | **Aceitar automaticamente** (TOFU) |
| Saída | **Um TXT consolidado** (como hoje) |
| Idioma | **Inglês** (GUI, mensagens, rótulos do relatório) |

**Premissas (corrigir no review se estiverem erradas)**
- Continua em PowerShell e `plink`, rodando no **Windows PowerShell 5.1 nativo** sem instalar nada no notebook de campo (deve rodar também no pwsh 7).
- Continua **100% somente leitura** nos switches: só `terminal`, `show` e `exit`.
- Uma sessão SSH por switch, com paralelismo padrão de **4** (faixa 1–10) e nunca duas sessões no mesmo IP.
- Na varredura, conta como alvo quem tem TCP/22 aberto e banner SSH `Cisco`. O ping é só informativo, porque ICMP costuma ser bloqueado em OT. **O plink nunca é executado contra hosts não-Cisco**, a menos que o operador marque manualmente.
- O `-Mode Fast|Standard|Deep` atual continua funcionando.

## Arquitetura

```
 Start-Collector.cmd ──► CiscoC9200-OT-Investigation.ps1 (entry: params → GUI ou headless)
                               │
            ┌──────────────────┴───────────────────┐
        gui/Gui.ps1 + MainWindow.xaml          headless runner (console)
        (WPF, DispatcherTimer 250 ms)          (loop Step + Start-Sleep 250 ms)
            └──────────────┬───────────────────────┘
                     MESMO ENGINE (lib/*.ps1), não-bloqueante, "tick-driven"
   Settings ─ Commands ─ Network(scan) ─ HostKeys ─ Plink ─ Collector ─ LogFilter ─ Report
```

**Modelo de execução (decisão central):** um engine **não-bloqueante, avançado por "ticks"**, numa única thread.
- Todo trabalho pesado já é assíncrono fora do PowerShell: processos `plink.exe`, `Ping.SendPingAsync`, `TcpClient.ConnectAsync` e `StreamReader.ReadAsync`.
- `Step-NetworkScan` e `Step-CollectionRun` só fazem *polling*: iniciam o próximo trabalho se há vaga, leem a saída disponível e tratam timeouts e conclusões, depois retornam em milissegundos.
- Na GUI, o `DispatcherTimer` chama o *step*, e a janela nunca trava.
- No CLI, um loop com `Start-Sleep`.
- **Sem runspaces e sem acesso cross-thread à UI.** Funciona igual no 5.1 e no 7, e é testável sem GUI.

## Estrutura de arquivos

```
CiscoC9200-OT-Investigation.ps1   entry point (mantém o nome; params legados + novos)
Start-Collector.cmd               duplo-clique: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA (console minimizado)
settings.default.json             defaults + presets embutidos (IPs de documentação 192.0.2.0/24) — versionado
settings.json                     escolhas salvas do operador — .gitignore
known_hosts.json                  fingerprints aceitos por TOFU — .gitignore
lib/Settings.ps1                  load/merge/validar/salvar JSON; presets; mapeamento -Mode legado
lib/Commands.ps1                  catálogo por categoria; VLAN/MAC/fontes de log; allowlist read-only
lib/Network.ps1                   expansão CIDR; scan assíncrono ping + TCP/22 + banner SSH
lib/HostKeys.ps1                  pinned → known_hosts.json → cache PuTTY (HKCU) → probe; TOFU; mudança de chave
lib/Plink.ps1                     resolver plink; detectar -pwfile via --help; montar args; iniciar/ler processo
lib/Collector.ps1                 estado da execução: fila, vagas, estados por switch, timeout, cancelamento
lib/LogFilter.ps1                 parse de timestamps Cisco, janela de N dias, cobertura, resumo por severidade
lib/Report.ps1                    TXT consolidado: cabeçalho, bloco por switch ao concluir, resumo final
gui/MainWindow.xaml               layout WPF
gui/Gui.ps1                       binding settings↔controles, timer, grids de progresso, log de eventos
tests/*.Tests.ps1                 Pester 5 (unit + integração)
tests/fixtures/                   saídas reais/sintéticas: show logging (vários formatos), show clock, mensagens plink
tests/lab/                        fake-plink.exe (C# compilado via Add-Type no 5.1) + listeners de banner em 127.0.0.x
docs/superpowers/specs/2026-11-05-v2-gui-scan-parallel-design.md   cópia desta spec
.gitignore                        settings.json, known_hosts.json, relatórios *.txt, plink.exe
README.md                         atualizado (EN): GUI, presets, scan, paralelo, migração do config antigo
```
`switches.example.ps1` é removido (substituído por `settings.default.json`; README traz a migração).

## Design por componente

### 1. Settings JSON e presets (`lib/Settings.ps1`)
- Carrega `settings.default.json` e sobrepõe `settings.json` com merge profundo: objetos se mesclam, arrays são substituídos.
- Valida faixas e enums e converte tudo em **hashtables**. No 5.1 o `ConvertFrom-Json` não tem `-AsHashtable` e o StrictMode 2.0 lança erro em propriedade ausente; com o merge, chaves faltantes recebem o default.
- Salva com `ConvertTo-Json -Depth 10`, em UTF-8 sem BOM e com escrita atômica (arquivo temporário seguido de replace).
- Seções:
  - `connection`: username, plinkPath, sshPort, maxParallel, perSwitchTimeoutSeconds, connectTimeoutSeconds, hostKeyPolicy `AutoAccept|Strict`, onHostKeyChange `Block|Accept`;
  - `targets`: switches[{name, ip, enabled}], scanRanges[], includeNonCiscoSsh, maxScanHosts=1024;
  - `hostKeys` (fixadas manualmente) e `report.directory`;
  - `presets[]` e `lastUsed`.
- Formato de um preset: `{ name, description, categories[], logs{sources[Buffer|RebootHistory], days(0=all)}, vlans{mode All|Only, list[]}, macs[] }`.
- Presets embutidos:

| Preset | Categorias | Logs |
|---|---|---|
| Quick triage (3 days) | Identity, Health, Interfaces, Layer2, Layer3, Security, ConfigExtracts, Logs | Buffer, 3 d |
| Standard investigation (30 days) | + Detailed | Buffer + RebootHistory, 30 d |
| Deep investigation (90 days) | + SanitizedRunningConfig | Buffer + RebootHistory, 90 d |
| Logs only | Identity, Logs | Buffer + RebootHistory, 30 d |
| VLAN focus | Identity, Layer2, Logs | Buffer, 3 d, VLAN mode = Only |
| MAC trace | Identity, Layer2, Layer3 | — (exige lista de MACs) |

- O `-Mode Fast|Standard|Deep` legado mapeia para as categorias equivalentes, com logs = tudo, sem filtro.

### 2. Catálogo de comandos (`lib/Commands.ps1`)
- Refatora `New-CiscoCommandList` (hoje em `CiscoC9200-OT-Investigation.ps1:128`) em **categorias de dados**, mantendo a ordem atual: Identity, Health, Interfaces, Layer2, Layer3, Security, ConfigExtracts, Logs, Detailed, SanitizedRunningConfig, TechSupport.
- Sempre presentes: `terminal length 0`, `terminal width 511` e `show clock detail` (referência de tempo dos logs). O `exit` fecha a lista.
- **Escopo de VLAN:**
  - **All**: comandos globais, como hoje.
  - **Only**: troca `show mac address-table dynamic` e `show spanning-tree detail` por versões por VLAN.
  - Em ambos os modos, cada VLAN da lista ganha `show vlan id N`, `show spanning-tree vlan N detail` e `show mac address-table vlan N`.
  - O parser aceita `10,20,30-35`, na faixa 1–4094, com no máximo 64 VLANs.
- **MAC:** reaproveita `Convert-ToCiscoMac` (`:89`) e gera `show mac address-table address M` mais `show ip arp M`.
- **Fontes de log:**
  - `Buffer` gera `show logging` completo, substituindo o `| last 300`.
  - `RebootHistory` gera `show logging onboard switch active uptime detail`.
- **Allowlist de segurança:** toda linha deve casar com `^(terminal (length|width) \d+|show .+|exit)$` e não pode conter `| redirect`, `| tee` ou `| append`, que gravariam na flash. Com isso, entrada do usuário (VLAN/MAC) não injeta comando.

### 3. Varredura de rede (`lib/Network.ps1`)
- `Expand-IPv4Cidr`:
  - aceita CIDR /16–/32 e IP único, em lista separada por vírgula;
  - /24 rende 254 hosts, sem rede e broadcast;
  - limite total configurável de `maxScanHosts=1024`, para evitar /16 acidental em OT.
- `Start-NetworkScan` / `Step-NetworkScan`:
  - até 64 hosts em paralelo;
  - por host, **1 ICMP echo** (`Ping.SendPingAsync`, 1000 ms) e **1 conexão TCP** na porta SSH (`ConnectAsync`, 1500 ms);
  - se a porta conecta, lê o banner SSH (até 2 s) e fecha. Não há autenticação nem envio de credencial;
  - tudo por polling de `IsCompleted` com deadlines, descartando os objetos ao final.
- Classificação: `Cisco` quando o banner casa com `^SSH-[\d.]+-Cisco`.
- Outros banners SSH aparecem na lista **desmarcados**. Com `includeNonCiscoSsh=true` eles já vêm marcados, mas o padrão é false.
- Host que só responde ping aparece como "alive, SSH closed": é informação útil para a investigação e não vira alvo.
- O resultado alimenta a lista de alvos e o RESUMO do TXT.
- A seção de varredura existe na GUI e no CLI (`-Scan`).
- Alvos configurados que não foram varridos recebem o mesmo *pre-check* em paralelo no início da execução. Ele substitui o `Test-TcpPort` sequencial de 5 s por switch (`:104`, `:409`).

### 4. Host keys com auto-accept (`lib/HostKeys.ps1`)
- Ordem de resolução: chave fixada no settings, depois `known_hosts.json`, depois cache do PuTTY (`HKCU:\Software\SimonTatham\PuTTY\SshHostKeys`, valores `<alg>@<porta>:<ip>`), e por fim **probe**.
- **Probe** (só quando a chave é desconhecida): `plink -ssh -batch -noagent -P <porta> <ip>`, **sem `-l` e sem senha**.
  - Em `-batch`, uma chave fora do cache faz o plink imprimir o fingerprint e encerrar com "Connection abandoned", antes da autenticação.
  - O regex `(ssh-ed25519|ssh-ed448|ssh-rsa|ssh-dss|ecdsa-sha2-nistp\d+) \d+ (SHA256:[A-Za-z0-9+/]{43})` extrai o fingerprint, que é salvo no `known_hosts.json` (firstSeen/lastSeen).
  - A coleta usa `-hostkey SHA256:<43 chars>`, o formato documentado do PuTTY.
  - Na fase 6, validar com o plink 0.84 instalado: fixture da mensagem real e aceitação do formato.
- **Chave mudou** num IP conhecido (mensagem de mismatch do plink):
  - política padrão **Block**: o switch é pulado com alerta claro na GUI e no TXT;
  - `onHostKeyChange=Accept`: atualiza a chave, registra antiga e nova no relatório e tenta de novo uma vez.
- Cada bloco do TXT registra `HOST KEY: <fp> (source: pinned | known_hosts | PuTTY cache | auto-accepted on first use)`.
- A política `Strict` continua disponível: chave desconhecida faz o switch ser pulado.

### 5. Engine de coleta paralela (`lib/Collector.ps1` + `lib/Plink.ps1`)
- `New-CollectionRun`:
  - deduplica os alvos por IP;
  - cria a pasta temporária com ACL restrita ao usuário;
  - escreve **um** arquivo de comandos e **um** `-pwfile` por execução, em vez de um por switch.
- Estados por switch: `Queued → Precheck → HostKey → Collecting → Finalizing → Done | TimedOut | Failed | Skipped | Cancelled`, com etapa atual, tempo, bytes recebidos e índice do comando atual (*best effort*, pelo eco do prompt).
- `Step-CollectionRun`:
  - lê stdout/stderr com `StreamReader.ReadAsync` por polling, o que dá progresso ao vivo sem callbacks em outra thread;
  - aplica o timeout duro por switch (Kill, guardando a saída parcial, como hoje);
  - preenche as vagas até `maxParallel` e nunca abre duas sessões no mesmo IP;
  - finaliza o switch: filtra os logs e grava o bloco no TXT.
- `Stop-CollectionRun` é usado em Cancel, ao fechar a janela e no `finally` do CLI (Ctrl+C). Ele mata os plink em execução, marca os switches como `Cancelled`, grava o resumo e **apaga a pasta temporária com o `-pwfile`**.
- Detecção de `-pwfile` (correção do bug):
  - executa `plink --help` via `System.Diagnostics.Process`, que captura stdout e stderr sem o NativeCommandError do 5.1, e procura `-pwfile`;
  - se não achar, usa `-V`: `Release >= 0.77` conta como suportado;
  - sem suporte, cai em `-pw` com aviso visível.
- O resolvedor procura o plink ao lado do script, depois no PATH, depois em `C:\Program Files\PuTTY\plink.exe`, ou usa o caminho do settings.
- Reaproveita `Quote-ProcessArgument` (`:98`), `Convert-ToPlainText` (`:75`) e o padrão de `ProcessStartInfo` de `Invoke-SwitchCollection` (`:255`), renomeando `$args` para `$plinkArgs`.

### 6. Filtro de logs por período (`lib/LogFilter.ps1`)
- **"Agora" de referência:** o relógio do switch, lido de `show clock detail`. O `*` indica relógio não autoritativo e "No time source" indica sem NTP; os dois casos geram alerta. Se não der para ler, usa o relógio do PC, e isso fica anotado.
- **Parse das entradas:**
  - formato `[seq: ][*|.]Mon dd [yyyy] hh:mm:ss[.mmm] [TZ]: %FAC-SEV-MNEMONIC: msg`;
  - linhas de continuação são anexadas à entrada anterior;
  - timestamps no formato uptime (`1w2d:`) são contados e mantidos, com aviso de que o filtro por data não se aplica a eles.
- **Inferência de ano** quando o timestamp não tem ano: usa o ano da referência, e se a data cair mais de 2 dias no futuro, subtrai 1 ano.
- O filtro funciona sobre o stdout inteiro, pelo padrão das linhas de syslog, sem depender de eco de comando. Os valores de "Log Buffer (N bytes)", "messages logged", "Persistent logging" e "File logging" saem do cabeçalho do `show logging`.
- **Cobertura:** entrada mais antiga e mais nova, total e quantas caem na janela. Exemplo: `"buffer reaches back 6 days — requested 30 days: NOT COVERED"`.
- Gera também a contagem por severidade e o top 10 de mnemonics (`%LINK-3-UPDOWN`, `%PM-4-ERR_DISABLE`…).
- Os timestamps de log são UTC por padrão e o `show clock` é local, então a borda da janela tem precisão de ± horas. Isso fica documentado.

### 7. Relatório TXT consolidado (`lib/Report.ps1`)
- O nome continua `Cisco_C9200_OT_Investigation_<stamp>.txt`, na pasta do script ou em `report.directory`.
- **Cabeçalho**, escrito no início: metadados, preset e seleção completa, política de host key, *command plan* (escrito uma vez, já que é igual para todos) e tabela da varredura.
- **Bloco por switch**, escrito **quando o switch termina** (o append é feito só pela thread do engine), contendo:
  - cabeçalho e host key;
  - `LOG SUMMARY` (cobertura e severidades);
  - `LOG ENTRIES — LAST N DAYS`;
  - `RAW CLI OUTPUT` intacto, como evidência;
  - `PLINK STDERR`;
  - `COLLECTION RESULT`.
- **Final:** `COLLECTION SUMMARY` na ordem de entrada (Name, IP, Status, Duration, KB, Log coverage, Notes), `RUN EVENT LOG` e totais. O resumo é escrito mesmo em caso de cancelamento.

### 8. GUI WPF (`gui/MainWindow.xaml` + `gui/Gui.ps1`)
- WPF com XAML num arquivo separado. O layout fica editável sem mexer na lógica, ele é DPI-aware no Windows 11 e o `DataGrid` faz binding com `DataTable`, que atualiza sozinho.
- A janela carrega via `XamlReader`. Todo handler passa por um wrapper que captura exceções e as mostra no log de eventos ou num MessageBox, para a GUI nunca morrer em silêncio.
- **Barra de preset** sempre visível: `Preset [▼]  [Save] [Save as…] [Delete]`. Escolher um preset preenche os controles; qualquer edição marca "(modified)".
- Abas:
  - **Targets**: grid de switches configurados (Name, IP, Use) com Add/Remove; campo *Scan ranges*, botão Scan com barra de progresso e grid de resultados (IP, Ping, TCP22, Banner, Cisco, Use); "Select all Cisco" e "Add selected to saved switches".
  - **Collection**: checkboxes das categorias, com custo (fast/slow/very slow); Logs com as fontes (Buffer / Reboot history) e o período (3/7/30/90/All/Custom N); VLANs (All / Only listed, mais a lista); MACs.
  - **Connection**: Username, Password (`PasswordBox`, nunca salvo), plink path com Browse e o status do `-pwfile`, Max parallel (1–10), timeouts, política de host key, pasta do relatório.
  - **Run & Monitor**: `[Start] [Cancel] [Open report] [Open folder]`; fase atual ("Scanning 212/254" / "Collecting — 4 running · 5 queued · 3 done · 1 failed"); barra geral; grid por switch (Switch, IP, Status, Step, Time, KB, Logs); log de eventos com auto-scroll.
- Esboço da aba Run & Monitor:
```
 [Start] [Cancel] [Open report] [Open folder]     Collecting — 4 running · 5 queued · 3 done · 1 failed
 ███████████░░░░░░░░░░░ 4/13
 Switch      IP           Status       Step                              Time   KB    Logs (30d)
 OT-SW-01    10.20.30.11  Done         —                                 58s    812   41 · covers 6d only
 OT-SW-02    10.20.30.12  Collecting   show interfaces (52/71)           31s    420
 10.20.30.21 10.20.30.21  HostKey      auto-accepted SHA256:Xy3…         2s
 OT-SW-04    10.20.30.14  Skipped      host key CHANGED (policy: Block)  —
 ── Event log ─────────────────────────────────────────────────────────────────────────
 10:22:01  Scan finished: 254 probed · 9 alive · 7 SSH · 6 Cisco
 10:22:03  OT-SW-01 started (host key: PuTTY cache)
```
- **Validação antes do Start:**
  - pelo menos 1 alvo, usuário e senha preenchidos e plink encontrado;
  - lista de VLANs válida, e o modo `Only` exige a lista;
  - MACs válidos, e o preset MAC trace exige pelo menos um.

  Os erros aparecem destacados no próprio controle.
- `lastUsed` é salvo no `settings.json` ao clicar em Start e ao fechar a janela.
- Fechar durante a execução pede confirmação e chama `Stop-CollectionRun`.
- Se o WPF não carregar (Server Core), aparece uma mensagem com a linha de comando headless.

### 9. Entry point, CLI e launcher
- Sem parâmetros, abre a GUI.
- `-NoGui` roda headless com `-Preset`, `-Targets`, `-Scan`, `-LogDays`, `-LogSources`, `-Vlans`, `-VlanMode`, `-Macs`, `-MaxParallel`, `-PerSwitchTimeoutSeconds`, `-SshConnectTimeoutSeconds` e `-SettingsPath`, com progresso no console.
- `-Mode Fast|Standard|Deep` implica `-NoGui` com o preset equivalente, então o uso documentado no README continua igual.
- A senha continua sendo pedida por `Read-Host -AsSecureString`.
- A faixa do timeout passa de 60–180 para **60–900**, com padrão de 175 s.
- `Start-Collector.cmd` abre a GUI com duplo clique.

## Fases de implementação (TDD em cada uma)

0. **Preparação**
   - `git clone` em `C:\44\5\cisco-c9200-ot-investigation-collector` e branch `feature/v2-gui-scan-parallel`.
   - Instalar **Pester 5** (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser`) no 5.1 e no 7; hoje só existe o 3.4 nativo.
   - Salvar esta spec em `docs/superpowers/specs/`.
1. **Golden e bugs**
   - Extrair via AST o `New-CiscoCommandList` original e gravar as listas legadas Fast/Standard/Deep (com e sem VLAN/MAC) como fixtures.
   - Corrigir a detecção do `-pwfile` e o `$args`.
2. **Commands**: catálogo, seleção, parsers de VLAN/MAC e a allowlist read-only. Os testes de golden passam, com as diferenças intencionais documentadas: `| last 300` vira `show logging` e entra `show vlan id`.
3. **Settings**: JSON default e de usuário, merge, validação, presets e mapeamento do `-Mode`.
4. **LogFilter e Report**: fixtures de todos os formatos de timestamp, virada de ano, cobertura e blocos do TXT.
5. **Network**: CIDR e scan, com teste de integração em listeners locais em `127.0.0.x:<porta alta>` emitindo banners Cisco e OpenSSH.
6. **HostKeys**: parse das mensagens do plink (fixtures), TOFU, mudança de chave e leitura do registro (abstraída para teste).
7. **Collector e CLI headless**, usando o fake-plink.exe:
   - concorrência ≤ N;
   - IP nunca duplicado;
   - timeout com saída parcial;
   - cancelamento que limpa os processos e o `-pwfile`;
   - cada bloco aparece uma única vez.
8. **GUI**: XAML e wiring. Smoke test que carrega a janela sem exibi-la, confere os controles nomeados e faz o roundtrip settings↔controles.
9. **Fechamento**: launcher, `.gitignore`, README (EN) com migração do config antigo e verificação final no 5.1 e no 7.

Commits só se você pedir (sugestão: um por fase, nesta branch). Nada é enviado ao GitHub sem autorização explícita.

## Verificação

- **Automatizada:** `Invoke-Pester tests` verde em `powershell.exe` 5.1 **e** em `pwsh` 7.
- **Laboratório sem rede real** (`tests/lab`): listeners de banner em 127.0.0.10–.15 e um fake-plink que registra cada invocação e simula:
  - saída normal com logs cobrindo 120 dias;
  - switch lento (timeout);
  - falha de autenticação;
  - host key desconhecida;
  - host key alterada.

  Executar no headless com `-MaxParallel 4` e conferir:
  - concorrência máxima de 4;
  - nenhum plink disparado contra o host OpenSSH;
  - contagens das janelas de 3/30/90 dias batendo com a fixture;
  - TXT com um bloco por switch e o resumo;
  - depois do Cancel, nenhum `fake-plink` vivo e a pasta temporária apagada.
- **GUI:** abrir pelo `Start-Collector.cmd` apontando para o laboratório. A conferência visual do andamento é sua.
- **Checklist em switch real** (você, numa janela autorizada):
  1. Um switch com Quick triage e paralelo 1, comparando com a saída antiga.
  2. Conferir a saída de `show logging onboard switch active uptime detail` e dos comandos por VLAN.
  3. Varrer a /24 de gerência e conferir a classificação Cisco.
  4. Switch fora do cache PuTTY: verificar que o fingerprint foi registrado e que a segunda execução usa `known_hosts.json`.
  5. Quatro em paralelo, comparando o tempo com o sequencial.
  6. Cancelar no meio e conferir que não sobrou nenhum `plink.exe`.
  7. Verificar se o `plink -m` ecoa os comandos no C9200, o que afeta só o indicador de "comando atual".

## Fora do escopo agora (próximas iterações)
- Ler arquivos de *persistent logging* da flash. Nesta versão o coletor só detecta e reporta se está habilitado.
- Integração com servidor syslog.
- Menu texto no console (o CLI cobre o uso headless).
- Exportar CSV/HTML.
- Credential Manager.
- Assinatura de código para ambientes AllSigned.

## Riscos
- **Auto-accept de host key** expõe a um MITM no primeiro contato (decisão consciente). A mitigação é o `known_hosts.json` com bloqueio quando a chave muda.
- **Formatos que precisam de validação no equipamento:**
  - mensagens do plink e formato aceito pelo `-hostkey` (mitigação: regex tolerante, fixtures e teste com 0.84);
  - sintaxe do OBFL ou de comandos por VLAN conforme a release (mitigação: o erro de CLI fica no relatório como evidência, como hoje).
- **Logs em UTC versus `show clock` local** dão uma borda da janela de ± horas, o que fica documentado.
- **A varredura gera tráfego**, ainda que leve, na rede OT. Exige autorização, e o README traz um aviso.
