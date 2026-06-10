# Groovy_Tang — Specification et architecture du projet

**Version 0.2 — 2026-06-05**
**Auteur :** Subs (avec assistance Claude)
**Statut :** Document de référence vivant, à mettre à jour au fil des décisions

**Changements v0.2 :** intégration des findings du projet `nand2mario/tangcore`
(notamment nestang/hdmi2 basé sur sameer/hdl-util/hdmi). Conséquences : audio
HDMI devient la stratégie V1 (au lieu du jack analogique), module HDMI complet
identifié comme base de notre Phase 2 plutôt qu'à écrire from scratch.

---

## Table des matières

1. Vision et scope
2. Architecture matérielle
3. Architecture logicielle globale
4. Compatibilité avec Groovy_MiSTer (V1 = clone fonctionnel)
5. Analyse du protocole Groovy_MiSTer
   - 5.1 Vue d'ensemble
   - 5.2 Commandes et formats binaires
   - 5.3 Streaming des pixels
   - 5.4 ACK et état FPGA
   - 5.5 Mode change et solver PLL
   - 5.6 Audio
   - 5.7 Inputs
   - 5.8 Modes RGB
6. Architecture FPGA du Tang Primer 20K
   - 6.1 Suppression de la couche HPS
   - 6.2 Décomposition en couches d'abstraction
   - 6.3 Modules réutilisables depuis Groovy_MiSTer
   - 6.4 Modules à écrire from scratch
   - 6.5 Module HDMI réutilisé depuis tangcore (sameer/hdl-util/hdmi)
7. Solver PLL Gowin rPLL
8. Stratégie super-résolution HDMI
9. Roadmap d'implémentation
10. Questions ouvertes
11. Références

---

## 1. Vision et scope

**Groovy_Tang** est un récepteur CRT FPGA basé sur le **Sipeed Tang Primer 20K Dock** (Gowin GW2A-LV18), conçu comme alternative économique au DE10-Nano pour le projet Groovy_MiSTer.

### Cibles techniques

- [DÉCIDÉ] FPGA-only : aucun SoC ARM, aucun OS, tout en logique configurée
- [DÉCIDÉ] Sortie vidéo : HDMI/TMDS sur le connecteur HDMI du Tang Primer 20K Dock
- [DÉCIDÉ] Cible principale : 15 kHz CRT (jusqu'à 384×288 progressif ou 640×480 interlaced field-based)
- [DÉCIDÉ] Best-effort : 31 kHz progressif jusqu'à 640×480 selon compression
- [DÉCIDÉ] Hors scope : modes >640×480 progressif
- [DÉCIDÉ] Réseau : Ethernet 100Mbps (limite intrinsèque du board, ~12 MB/s utiles)

### Cibles fonctionnelles

- [DÉCIDÉ] V1 : **clone fonctionnel de Groovy_MiSTer** avec compatibilité protocole stricte
- [DÉCIDÉ] V1 : décodeur LZ4 hardware porté depuis Psakhis (`rtl/lz4.v`, fenêtre 8 KB)
- [DÉCIDÉ] V1 : modes RGB888, RGBA888, RGB565
- [DÉCIDÉ] V1 : interlaced supporté (field-based)
- [DÉCIDÉ] V1 : audio stream
- [À DÉCIDER] V1 : inputs (joystick + PS/2) — secondaire, peut être V1.x
- [DÉCIDÉ] V2+ : extensions propres (RLE, QOI, autres FPGA cibles) sans casser V1

### Cibles écosystème

- [DÉCIDÉ] Le code spécifique Tang/Gowin et les wrappers d'abstraction sont isolés dans `rtl/vendor/gowin/` et `rtl/board/tang_primer_20k/`
- [DÉCIDÉ] Les blocs génériques (timing vidéo, LZ4, sound, TMDS) dans `rtl/generic/` doivent rester portables vers d'autres FPGA
- [DÉCIDÉ] Compatibilité applications PC : **GroovyMAME, RetroArch, Mednafen, 86Box existants utilisables tels quels** (seule l'IP cible change)
- [DÉCIDÉ] Licence : GPLv2+ (alignée sur Groovy_MiSTer dont on hérite du code)

---

## 2. Architecture matérielle

### Tang Primer 20K Dock

- **FPGA :** Gowin GW2A-LV18PG256C8/I7
- **Logique :** 20736 LUT4, 15552 FF
- **Mémoire :** 828 Kbits B-SRAM (~104 KB), 41 Kbits Shadow SRAM
- **DSP :** 48 multiplieurs 18×18
- **PLL :** 4 rPLL (Gowin), reconfigurables dynamiquement
- **DDR3 :** 128 MB embarqué sur le core board
- **Ethernet :** 10/100 Mbps RJ45 (sur le Dock)
- **Vidéo :** Connecteur HDMI sur le Dock (TMDS via pads LVDS du FPGA)
- **Audio :** Jack 3.5mm (sortie analogique sur le Dock)
- **Programmation :** USB via BL616 intégré (USB-JTAG)

### Référence horloge

- Oscillateur 27 MHz onboard (pin `H11` à confirmer dans le schématique)
- Utilisé comme refclk pour les PLLs et la logique système

### Connecteurs disponibles

- HDMI (sortie principale)
- Ethernet RJ45 (data + inputs)
- 4× PMOD (utilisable pour debug, capture, futur input)
- Jack 3.5mm audio
- USB-JTAG (programmation)

---

## 3. Architecture logicielle globale

### Comparaison Groovy_MiSTer vs Groovy_Tang

```
GROOVY_MISTER (DE10-Nano)              GROOVY_TANG (Tang Primer 20K)
─────────────────────────             ─────────────────────────

  GroovyMAME (PC)                       GroovyMAME (PC) ← inchangé
        ↓ UDP                                 ↓ UDP
  ┌─────────────────┐                   ┌──────────────────┐
  │  HPS Linux ARM  │                   │                  │
  │  MiSTer_groovy  │                   │      FPGA        │
  │   • Parse UDP   │                   │  • Parse UDP RX  │
  │   • Solver PLL  │                   │  • Solver PLL    │
  │   • Mem shared  │                   │  • DDR3 ctrl     │
  └────────┬────────┘                   │  • LZ4 decoder   │
           │ Avalon-MM                  │  • Video timing  │
  ┌────────┴────────┐                   │  • TMDS out      │
  │  FPGA Cyclone V │                   │                  │
  │  • DDR3 ctrl    │                   └────────┬─────────┘
  │  • LZ4 decoder  │                            ↓
  │  • Video timing │                          HDMI
  │  • VGA out      │
  └────────┬────────┘
           ↓
        VGA analog → CRT
```

### Conséquences architecturales

- [DÉCIDÉ] **Tout ce que fait `MiSTer_groovy` (HPS) est repris en Verilog** dans Groovy_Tang
- [DÉCIDÉ] **Le module `hps_ext.v` de Groovy_MiSTer disparaît** complètement — remplacé par un parseur UDP direct
- [DÉCIDÉ] **Le solver PLL passe du C++ (HPS) au Verilog (FPGA)** — option A retenue (côté FPGA), à reconsidérer si trop complexe
- [DÉCIDÉ] **La sortie vidéo passe de VGA analogique (DAC) à HDMI/TMDS**

### Côté PC : aucune modification requise pour la V1

Les applications PC existantes (GroovyMAME, RetroArch, Mednafen, 86Box) communiquent avec Groovy_Tang **exactement comme avec un MiSTer**. Le seul changement : l'adresse IP cible.

Cela découle de la **compatibilité protocole stricte** (décision Q2 du 2026-06-05).

---

## 4. Compatibilité avec Groovy_MiSTer

### Principe directeur

[DÉCIDÉ] **V1 = clone fonctionnel.** Tout ce qui sort sur le câble Ethernet vers Groovy_Tang doit être bit-pour-bit identique à ce qui sort vers un MiSTer. Tout ce qui revient en ACK doit l'être aussi.

### Ce qu'on hérite tel quel

- Format binaire des paquets (8 commandes, voir section 5)
- Sémantique des commandes (INIT, SWITCHRES, BLIT, AUDIO, GET_STATUS, etc.)
- Streaming raw bytes des pixels après commande BLIT (pas de header par paquet)
- Format de l'ACK (13 bytes)
- Ports UDP : 32100 (data), 32101 (inputs), 32105 (GMC)
- Algorithme LZ4 avec fenêtre 8 KB (variant low-memory)
- Mécanisme frame_delta et frame_dup
- Modes RGB : 0=RGB888, 1=RGBA888, 2=RGB565
- Auto frame delay côté PC (basé sur vCountSync)

### Ce qu'on adapte

- **Mode-change pipeline** : la séquence de reconfiguration PLL passe de "HPS écrit M0/M1/C0/C1/K dans mémoire partagée" à "logique FPGA programme directement la rPLL Gowin"
- **Solver PLL** : algorithme adapté aux contraintes de la rPLL Gowin (VCO range, dividers valides)
- **Sortie vidéo** : VGA analogique 8-8-8 → TMDS HDMI avec super-résolution horizontale × N
- **VRAM** : architecture interne adaptée à la BRAM Gowin et au contrôleur DDR3 Gowin

### Ce qu'on simplifie ou drop

- Pas de support XDP/AF_XDP côté serveur (notre serveur est FPGA, pas Linux)
- Pas de menu MiSTer / OSD complexe (peut-être un OSD minimal en V2)
- Pas de "logo MiSTer" au boot (CMD_GROOVY_LOGO ignoré)
- Audio jumbo frames : à voir si pertinent à 100M
- Pas de gestion de configuration via fichier `.ini` style MiSTer

### Compat protocole : que se passe-t-il si non respectée ?

Toute déviation du protocole oblige à **patcher GroovyMAME** (et toutes les autres apps). C'est faisable mais ça nous coupe de la maintenance upstream et de la communauté Groovy_MiSTer. La V1 doit donc être strictement compatible. Les extensions V2+ peuvent ajouter des commandes nouvelles (CMD_INIT_TANG_EXT par exemple) sans casser l'existant.

---

## 5. Analyse du protocole Groovy_MiSTer

### 5.1 Vue d'ensemble

- **Transport :** UDP unicast, IPv4
- **Pas de TCP, pas de handshake formel, pas de retransmission**
- **Le client (PC) est l'initiateur** : il pousse les paquets vers le récepteur (FPGA ou MiSTer)
- **Le serveur (FPGA) répond uniquement par des ACK** sur certaines commandes
- **Streaming model :** une commande de contrôle (1 paquet) est suivie d'un flux de paquets data "raw" sans en-tête, accumulés jusqu'à atteindre la taille attendue

### Ports UDP

| Port | Usage | Direction |
|---|---|---|
| **32100** | Data path principal (commandes + pixels + audio) | PC → FPGA + ACK FPGA → PC |
| **32101** | Inputs path (joystick, keyboard, mouse) | FPGA → PC |
| **32105** | "GMC" (Groovy MiSTer Cast ?) | À investiguer |

### 5.2 Commandes et formats binaires

Le premier byte de chaque paquet de commande identifie la commande :

```c
#define CMD_CLOSE            1   // Fin de session
#define CMD_INIT             2   // Init session
#define CMD_SWITCHRES        3   // Changement de mode vidéo (modeline)
#define CMD_AUDIO            4   // Démarrage burst audio
#define CMD_GET_STATUS       5   // Demande d'ACK status
#define CMD_BLIT_VSYNC       6   // [DEPRECATED] Blit ancien format
#define CMD_BLIT_FIELD_VSYNC 7   // Blit standard (avec field pour interlaced)
#define CMD_GET_VERSION      8   // Demande version
```

### Format détaillé de chaque commande

#### CMD_CLOSE (1 byte total)

```c
struct cmd_close {
    uint8_t cmd;  // = 1
};
```

#### CMD_INIT (5 bytes total)

```c
struct cmd_init {
    uint8_t cmd;          // = 2
    uint8_t lz4Frames;    // 0 = raw, 1 = LZ4 (autres valeurs : variants LZ4HC/adaptatif)
    uint8_t soundRateCode; // 0=none, 1=22050Hz, 2=44100Hz, 3=48000Hz
    uint8_t soundChan;    // nombre de canaux audio
    uint8_t rgbMode;      // 0=RGB888, 1=RGBA888, 2=RGB565
};
```

Le serveur répond par un ACK status (13 bytes).

#### CMD_SWITCHRES (26 bytes total)

```c
struct cmd_switchres {
    uint8_t  cmd;        // = 3
    double   pClock;     // Pixel clock en MHz, IEEE-754 little-endian
    uint16_t hActive;    // Largeur active
    uint16_t hBegin;     // Début hsync
    uint16_t hEnd;       // Fin hsync
    uint16_t hTotal;     // Total horizontal
    uint16_t vActive;    // Hauteur active
    uint16_t vBegin;     // Début vsync
    uint16_t vEnd;       // Fin vsync
    uint16_t vTotal;     // Total vertical
    uint8_t  interlace;  // 0=progressif, 1=interlaced, 2=interlaced FB progressive
};
```

**Note importante** : `pClock` est un `double` 64 bits en little-endian. Le récepteur doit traiter du float, ou bien le PC peut envoyer une représentation alternative en V2+.

Tous les autres champs sont **little-endian uint16_t**.

#### CMD_AUDIO (3 bytes total + audio stream)

```c
struct cmd_audio {
    uint8_t  cmd;        // = 4
    uint16_t soundSize;  // Taille du burst audio à suivre, en bytes
};
```

Puis le PC streame `soundSize` bytes d'audio en paquets UDP successifs (sans header).

#### CMD_GET_STATUS (1 byte total)

```c
struct cmd_get_status {
    uint8_t cmd;  // = 5
};
```

Le serveur répond par un ACK status (13 bytes).

#### CMD_BLIT_FIELD_VSYNC (8/9/12/13 bytes total + pixel stream)

Variable selon flags :

```c
// Cas 1 : 8 bytes — blit raw, pas de delta
struct cmd_blit_raw {
    uint8_t  cmd;       // = 7
    uint32_t frame;     // Numéro de frame
    uint8_t  field;     // 0=field 0 (ou progressif), 1=field 1, 2=auto
    uint16_t vSync;     // Ligne où sync, 0=auto frame delay
};

// Cas 2 : 9 bytes — blit raw avec frame_dup flag
// Identique au cas 1 + 1 byte supplémentaire = 0x01 (frame_dup, image identique à la précédente, pas de pixels à suivre)

// Cas 3 : 12 bytes — blit LZ4, pas de delta
struct cmd_blit_lz4 {
    uint8_t  cmd;       // = 7
    uint32_t frame;
    uint8_t  field;
    uint16_t vSync;
    uint32_t cSize;     // Taille compressée LZ4 en bytes
};

// Cas 4 : 13 bytes — blit LZ4 + delta flag
// Identique au cas 3 + 1 byte = 0x01 (frame_delta, le payload est un delta par rapport à la frame précédente)
```

#### CMD_GET_VERSION (1 byte total)

```c
struct cmd_get_version {
    uint8_t cmd;  // = 8
};
```

Le serveur répond par une version. Format à confirmer.

### 5.3 Streaming des pixels

**Caractéristique critique : les paquets de pixels après CMD_BLIT n'ont AUCUN header applicatif.**

Le récepteur entre dans un état `isBlitting = 1` après réception d'un CMD_BLIT_FIELD_VSYNC. Dans cet état :
- Tout paquet UDP reçu est traité comme un chunk de bytes pixel/LZ4
- Le récepteur accumule les bytes dans la VRAM via un compteur (`PoC_bytes_recv`)
- Quand le compteur atteint la taille attendue (`PoC_bytes_len` pour raw, ou `udp_lz4_size` pour LZ4), le récepteur revient à l'état idle

Taille attendue selon mode :
- RGB888 : `hActive × vActive × 3` (×1/2 si interlaced field)
- RGBA888 : `hActive × vActive × 4`
- RGB565 : `hActive × vActive × 2`
- LZ4 : exactement `udp_lz4_size` bytes

### MTU et fragmentation

- **MTU par défaut : 1500 bytes** (Ethernet standard)
- **MTU jumbo : 3800 bytes** (option `mister.mtu`)
- Le payload UDP utile = MTU - 28 (header IP + UDP) - 8 (headers Ethernet)
- En MTU 1500 : ~1472 bytes utiles par paquet

### Vulnérabilité aux pertes

**Aucune protection** : si un paquet de pixels est perdu pendant un blit, le récepteur attend toujours ses bytes manquants. Le timeout doit être géré côté serveur (détection "len <= 26 et != prev_len" pour repasser en état idle).

Cette fragilité est **acceptable sur LAN direct câble droit** (perte ~0) mais problématique sur d'autres topologies. C'est pourquoi Groovy_MiSTer recommande "direct connection".

### 5.4 ACK et état FPGA

**Format de l'ACK (13 bytes), envoyé après CMD_INIT, CMD_GET_STATUS, CMD_BLIT_VSYNC, CMD_BLIT_FIELD_VSYNC :**

```c
struct fpga_ack {
    uint32_t frame_echo;       // Echo du frame# envoyé dans le BLIT
    uint16_t vsync_echo;       // Echo du vsync envoyé
    uint32_t fpga_vga_frame;   // Frame counter côté FPGA
    uint16_t fpga_vga_vcount;  // Compteur vertical actuel côté FPGA
    uint8_t  status_bits;      // Bitfield :
                               //   bit 0 : vram_ready
                               //   bit 1 : vram_end_frame
                               //   bit 2 : vram_synced
                               //   bit 3 : vga_frameskip
                               //   bit 4 : vga_vblank
                               //   bit 5 : vga_f1 (field interlaced)
                               //   bit 6 : audio
                               //   bit 7 : vram_queue > 0
};
```

Le PC utilise ces données pour :
- Calculer le réseau ping (RTT entre BLIT et ACK)
- Synchroniser ses émissions futures sur le vcount de raster du FPGA
- Détecter les frameskips et les désynchronisations

### 5.5 Mode change et solver PLL

**Algorithme dans Groovy_MiSTer (côté HPS, fichier `pll.cpp`) :**

Le HPS Linux exécute un solver PLL Cyclone V :

```c
// Pseudo-code
void setSwitchres(packet) {
    pClock = (double) packet.pClock;
    
    // Calcule un multiplicateur d'horloge interne (super-rez équivalent)
    ce_pix = (pClock × 16 < 90) ? 16 :
             (pClock × 12 < 90) ? 12 :
             (pClock × 8 < 100) ? 8 :
             (pClock × 6 < 100) ? 6 : 4;
    
    // Cherche les coefficients PLL (M, C, K) pour atteindre pClock × ce_pix
    getMCK_PLL_Fractional(pClock × ce_pix, &M, &C, &K);
    
    // Écrit les coefficients dans des registres FPGA via Avalon-MM
    write_fpga_register(M0, M1, C0, C1, K, modeline_params);
}
```

Les contraintes spécifiques au Cyclone V (Fractional-N PLL) sont :
- VCO range : 400 MHz à 1500 MHz
- Ref clock : 50 MHz
- M (feedback divider) : 1 à 320
- C (output divider) : 1 à ?
- K (fractional, 32 bits) : 0 à 4294967295

**Pour Groovy_Tang, ces contraintes changent** :
- VCO range Gowin GW2A : à confirmer dans datasheet (typiquement 400-1200 MHz)
- IDIV (input divider) : 1-64
- FBDIV (feedback) : 1-64
- ODIV (output) : valeurs discrètes (2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128)

Voir section 7 pour le solver Gowin.

### Séquence de mode change

```
PC envoie CMD_SWITCHRES (26 bytes)
    ↓
Récepteur parse modeline + pclk
    ↓
Récepteur calcule coefficients PLL (M, C, K ou IDIV/FBDIV/ODIV)
    ↓
[Wait for vblank]   ← critique pour éviter glitch visuel
    ↓
[Désactiver pipeline TMDS, force blanking]
    ↓
[Reprogrammer PLL — attendre signal LOCK (~50-200 µs)]
    ↓
[Recharger compteurs htotal, vtotal, etc.]
    ↓
[Réactiver pipeline TMDS]
    ↓
Récepteur prêt à recevoir pixels du nouveau mode
```

**Dans Groovy_MiSTer, cette séquence est gérée côté HPS+FPGA via plusieurs registres.** Dans Groovy_Tang, on doit la reproduire en pure logique FPGA (state machine `mode_change_fsm`).

### 5.6 Audio

- Sample rates supportés : 22050, 44100, 48000 Hz
- Channels : configurable (1 ou 2 typiquement)
- Format : signed 16-bit PCM
- Transport : burst CMD_AUDIO suivi de raw bytes (comme les pixels)

**Modèle interne du core Groovy_MiSTer :** le module `sound.v` produit en sortie
deux signaux `sound_l_out[15:0]` et `sound_r_out[15:0]` qui sont des **samples
PCM 16 bits L/R**, mis à jour à un rythme proche du sample rate audio. Le top-level
`Groovy.sv` les expose comme deux ports `AUDIO_L`/`AUDIO_R`. C'est ensuite **le
framework MiSTer (sys/)** qui se charge du routage réel vers la sortie physique
(jack analogique du I/O board, ou data islands HDMI).

Cette **séparation est précieuse** : notre `sound.v` reste neutre vis-à-vis de la
destination. On peut router le même flux PCM stéréo vers le HDMI (data islands),
le jack du Dock, ou les deux en parallèle.

**Pour Groovy_Tang :** sortie via HDMI data islands en V1, voir section 6.5 pour
le module HDMI complet qu'on adopte (issu de tangcore/nestang). Le jack 3.5mm du
Dock reste possible en option additionnelle (sortie I2S vers DAC du Dock — à
investiguer schématique).

### 5.7 Inputs

Port UDP 32101 dédié aux inputs.

```c
// Joysticks
struct fpga_joy_inputs {
    uint32_t joyFrame;   // Frame# au moment de la lecture
    uint8_t  joyOrder;   // Numéro d'ordre du paquet
    uint16_t joy1;       // Bitmap des boutons joystick 1
    uint16_t joy2;       // Bitmap des boutons joystick 2
    char     joy1LXAnalog, joy1LYAnalog, joy1RXAnalog, joy1RYAnalog;
    char     joy2LXAnalog, joy2LYAnalog, joy2RXAnalog, joy2RYAnalog;
};

// PS/2
struct fpga_ps2_inputs {
    uint32_t ps2Frame;
    uint8_t  ps2Order;
    uint8_t  ps2Keys[32];   // Bit array, SDL scancodes
    uint8_t  ps2Mouse;      // Byte 0 : [yo,xo,ys,xs,1,bm,br,bl]
    uint8_t  ps2MouseX;
    uint8_t  ps2MouseY;
    uint8_t  ps2MouseZ;
};
```

Bitmap joystick :
```
bit 0  : RIGHT
bit 1  : LEFT
bit 2  : DOWN
bit 3  : UP
bit 4-13 : B1 à B10
```

**Pour Groovy_Tang V1.x :** support PMOD pour gamepads arcade ? Le Tang Primer 20K a 4 PMOD, on peut y câbler des inputs. Mais c'est secondaire pour V1.

### 5.8 Modes RGB

| Mode | Code | Octets/pixel | Description |
|---|---|---|---|
| RGB888 | 0 | 3 | R/G/B 8 bits chacun (24 bpp) — défaut |
| RGBA888 | 1 | 4 | R/G/B/A 8 bits chacun (32 bpp) |
| RGB565 | 2 | 2 | R5/G6/B5 (16 bpp), pour économiser la bande passante |

L'alpha en RGBA888 est utilisé pour... à investiguer (transparence en overlay ? canal de contrôle ?). À noter que RGBA888 coûte 33% de plus en bandwidth que RGB888 sans gain de qualité — son usage doit être justifié.

---

## 6. Architecture FPGA du Tang Primer 20K

### 6.1 Suppression de la couche HPS

Dans Groovy_MiSTer, le HPS Linux gère :
- Réception UDP (avec optionnellement XDP pour la perf)
- Parsing des commandes
- Solver PLL software
- Allocation mémoire DDR3 (regions LZ4_OFFSET_A/B/C/D, etc.)
- Communication FPGA via Avalon-MM bus (`groovy_FPGA_*` functions)
- Logging/debug
- Réponses ACK

**Dans Groovy_Tang, tout cela devient des modules Verilog FPGA.** Les implications majeures :

1. **Pas d'allocateur mémoire dynamique** : la DDR3 est partitionnée à la synthèse, regions fixes.
2. **Le solver PLL devient un module Verilog** OU s'exécute lookup-table-style depuis une ROM précomputée. C'est une décision à prendre (voir Q ouvertes).
3. **Le parseur UDP est en pure logique** : state machine qui parse le byte de commande puis les champs.
4. **Pas de logs en runtime** : seulement des signaux de debug exportables sur GPIO/PMOD ou via JTAG.

### 6.2 Décomposition en couches d'abstraction

[DÉCIDÉ] Le code RTL est segmenté en 4 couches strictes :

```
rtl/
├── vendor/                       # Couche 0 — Spécifique Gowin
│   └── gowin/
│       ├── rpll_gowin.v          # Wrapper rPLL avec reconfig dynamique
│       ├── ddr3_gowin.v          # Wrapper DDR3 controller Gowin
│       ├── eth_phy_gowin.v       # Wrapper RGMII Gowin
│       ├── tmds_serializer_gowin.v  # Wrapper OSER10 pour TMDS
│       ├── bram_dp_gowin.v       # Wrapper BRAM dual-port
│       └── async_fifo_gowin.v    # Wrapper FIFO async Gowin
│
├── board/                        # Couche 1 — Spécifique board
│   └── tang_primer_20k/
│       ├── top_tang_primer.v     # Top-level avec pin mapping
│       └── tang_primer_20k.cst   # Contraintes physiques
│
├── core/                         # Couche 2 — Logique projet
│   ├── groovy_packet_parser.v    # Parse les 8 commandes UDP
│   ├── groovy_mode_change_fsm.v  # Séquence vblank → reconfig PLL → reset
│   ├── groovy_ack_sender.v       # Génère les ACK 13 bytes
│   ├── groovy_pll_solver.v       # Solver PLL Gowin (ou interface vers LUT)
│   └── groovy_top.v              # Assemblage des blocs
│
└── generic/                      # Couche 3 — Réutilisable
    ├── ethernet/
    │   ├── eth_mac_rx.v          # MAC RX Ethernet
    │   ├── eth_mac_tx.v          # MAC TX Ethernet
    │   ├── eth_ipv4_parser.v     # Parser IPv4 / UDP
    │   └── eth_udp_tx.v          # Constructeur paquet UDP TX
    ├── compression/
    │   └── lz4_decoder.v         # Décodeur LZ4 (issu de Psakhis, wrappers Gowin)
    ├── video/
    │   ├── tmds_encoder.v        # Encodeur 8b/10b TMDS
    │   ├── video_timing_gen.v    # Générateur H/V counters paramétrable
    │   ├── hdmi_infoframe.v      # InfoFrames HDMI (interlaced, etc.)
    │   └── line_buffer.v         # Line buffer générique
    ├── audio/
    │   └── i2s_encoder.v         # (Si sortie audio via HDMI plus tard)
    └── memory/
        └── ring_buffer.v         # Ring buffer générique (frames pour DDR3)
```

Règles strictes :
- Un module dans `generic/` **n'utilise jamais une primitive vendor** (BRAM, PLL, OSER10, etc.).
- Si un module générique a besoin d'une telle primitive, il instancie un module dans `vendor/gowin/`.
- Quand on porte vers Xilinx/Lattice/Altera, on remplace seulement `vendor/` et `board/`.

### 6.3 Modules réutilisables depuis Groovy_MiSTer

Analyse fichier par fichier du repo `psakhis/Groovy_MiSTer/rtl/` :

| Fichier original | Lignes | Réutilisable ? | Destination Groovy_Tang | Adaptations |
|---|---|---|---|---|
| `rtl/lz4.v` | 571 | **Oui, 80%** | `rtl/generic/compression/lz4_decoder.v` | Remplacer les RAM 64-bit par wrappers Gowin |
| `rtl/vga.v` | 940 | **Partiel, ~40%** | Découpé : timing → `rtl/generic/video/`, VRAM → `rtl/core/` | Refonte complète de l'interface VRAM/DDR3 |
| `rtl/sound.v` | 233 | **Oui, 90%** | `rtl/generic/audio/sound_buffer.v` | FIFO et BRAM Gowin |
| `rtl/hps_ext.v` | 320 | **Non, 0%** | — | Remplacé par parseur UDP direct (groovy_packet_parser.v) |
| `rtl/pll.v` | 257 | **Non, 0%** | — | Réécrit comme `rtl/vendor/gowin/rpll_gowin.v` |
| `rtl/fifo_vga.v` | 189 | **Non, 0%** | — | Réécrit comme `rtl/vendor/gowin/async_fifo_gowin.v` |
| `rtl/fifo_sound.v` | 189 | **Non, 0%** | — | Idem |
| `rtl/ddram.sv` | 123 | **Non, 0%** | — | Réécrit comme `rtl/vendor/gowin/ddr3_gowin.v` (interface différente) |
| `rtl/binary_to_bcd.v` | 169 | **Oui, 100%** | `rtl/generic/binary_to_bcd.v` | Aucune |
| `rtl/lfsr.v` | 16 | **Oui, 100%** | `rtl/generic/lfsr.v` | Aucune |
| `rtl/cos.sv` | 46 | **Oui, 100%** | `rtl/generic/math/cos.sv` | Aucune |

**Total réutilisable :** ~1000 lignes sur ~3000 de RTL "métier" (hors Groovy.sv top-level qui est 100% MiSTer-specific).

### 6.4 Modules à écrire from scratch

Tout ce qui n'est pas dans le tableau ci-dessus, ni couvert par tangcore
(voir 6.5), ni absent de Groovy_MiSTer parce que fait en software par le HPS :

- **Ethernet MAC RX/TX** (Groovy_MiSTer utilise la stack Linux sur HPS, nous on doit faire en hardware)
- **Parseur IPv4 + UDP**
- **`groovy_packet_parser.v`** : remplace `groovy.cpp` côté HPS
- **`groovy_pll_solver.v`** : remplace `pll.cpp` côté HPS (ou lookup table — voir section 7)
- **`groovy_mode_change_fsm.v`** : remplace la séquence orchestée par le HPS
- **Wrappers Gowin** rPLL reconfigurable, DDR3 controller, BRAM, async FIFO
- **`top_tang_primer.v`** : top-level board-specific
- **Adaptation modeline-driven du module HDMI** de tangcore (voir 6.5)

### 6.5 Module HDMI réutilisé depuis tangcore (sameer/hdl-util/hdmi)

Le projet `nand2mario/tangcore` (notamment `nestang/src/hdmi2/`) fournit une
**adaptation Gowin** du module HDMI très réputé `sameer/hdl-util/hdmi`. C'est
une **mine d'or** qu'on adopte largement.

#### Contenu du module HDMI (≈ 1500 lignes SystemVerilog)

| Fichier | Lignes | Rôle |
|---|---|---|
| `hdmi.sv` | 375 | Top-level HDMI : génère timing, pilote data islands et serializer |
| `serializer.sv` | 300 | Sérialiseur TMDS, multi-vendor (OSER10 Gowin, OSERDESE2 Xilinx) |
| `tmds_channel.sv` | 169 | Encodeur 8b/10b + TERC4 d'un canal TMDS |
| `packet_picker.sv` | 201 | Choix des packets à émettre dans les data islands |
| `packet_assembler.sv` | 86 | Assemblage et insertion des packets |
| `audio_sample_packet.sv` | 109 | Encodage des samples audio |
| `audio_clock_regeneration_packet.sv` | 79 | N/CTS pour régénération horloge audio côté sink |
| `audio_info_frame.sv` | 53 | Audio InfoFrame (déclare format audio) |
| `auxiliary_video_information_info_frame.sv` | 80 | AVI InfoFrame (obligatoire HDMI) |
| `source_product_description_info_frame.sv` | 64 | SPD InfoFrame (identité source) |

#### Caractéristiques clés pour nous

- **Switch DVI/HDMI par parameter** : `DVI_OUTPUT=1` → DVI pur (pas de data
  islands, pas d'audio, plus simple), `DVI_OUTPUT=0` → HDMI complet avec audio.
  Excellent pour notre stratégie escalier.
- **Multi-vendor** : le pattern `define vendor (`GW_IDE` pour Gowin, etc.) est
  exactement le pattern qu'on veut adopter dans `rtl/vendor/`. Validé sur du
  hardware.
- **Audio "gratuit"** : interface attendue = `clk_audio` (généré par division
  depuis clk_pixel, ~5 lignes Verilog) + `audio_sample_word[1:0]` (2 samples
  PCM L/R). Toute la complexité TERC4 / packets / N/CTS / InfoFrames est dans
  le module.
- **Origine** : Sameer Puri (`sameer/hdl-util/hdmi`), THE référence open source
  pour HDMI sur FPGA.

#### Pattern d'horloge HDMI sur Gowin (validé par nestang)

```
osc 27 MHz
    ↓
gowin_pll_hdmi → clk_pixel_x5  (5 × pclk)
    ↓
CLKDIV (/5) → clk_pixel
    ↓
3× OSER10 → tmds[2:0]  (data channels)
                              ↓
                       ELVDS_OBUF → paires TMDS différentielles vers HDMI

tmds_clock = clk_pixel directement (single-ended → ELVDS_OBUF)
```

Le serializer utilise **clk_pixel × 5 en DDR** (deux bits par cycle) pour
atteindre les 10× bits du TMDS, ce qui évite de devoir générer un clk × 10
souvent hors plage des PLL Gowin sur les hautes résolutions. Astuce classique
mais bien validée ici.

#### Limites du module à adresser pour Groovy_Tang

**Limite 1 — Timing en parameter statique.** Le module `hdmi.sv` choisit ses
paramètres de timing via un `generate case (VIDEO_ID_CODE)` à la synthèse. Tous
les `frame_width`, `screen_width`, `hsync_pulse_start`, etc. sont des `wire
assign` constants. **Pour notre support de modelines arbitraires, il faut
forker** `hdmi.sv` pour rendre ces paramètres dynamiques (signaux d'entrée
plutôt que parameters). Travail estimé : modéré, quelques jours. Le reste du
module (encodeurs, packets, FSM data island) reste identique.

**Limite 2 — Pas d'interlaced.** Le module annonce explicitement "Pixel
repetition, interlaced scans and other special output modes are not implemented
(yet)". On devra l'étendre pour gérer field 0/1, demi-ligne, AVI InfoFrame
scan_info, etc. Travail estimé : significatif, à faire en Phase 9 de la
roadmap.

**Limite 3 — VIDEO_REFRESH_RATE en parameter** : utilisé pour calculer le N
audio. À rendre dynamique avec le reste de la modeline pour notre cas.

#### Conséquences pour le tableau 6.3 (modules à réécrire)

Plusieurs modules qu'on aurait dû écrire from scratch sont **maintenant fournis
par tangcore** :

- ~~`tmds_encoder.v`~~ → `hdmi2/tmds_channel.sv`
- ~~`tmds_serializer.v` (vendor)~~ → `hdmi2/serializer.sv` (multi-vendor)
- ~~`hdmi_infoframe.v`~~ → couvert par `hdmi2/*_info_frame.sv`
- ~~`audio I2S encoder`~~ → couvert par `hdmi2/audio_*.sv`

**Économie : ~900 lignes de Verilog qu'on n'aura pas à écrire**, ce qui est
considérable.

#### Licence et attribution

À vérifier précisément dans les fichiers source. Le projet original
`sameer/hdl-util/hdmi` est sous licence MIT-like. Tangcore l'utilise dans un
projet Apache 2.0 (firmware) avec cores sous licences variées. **Compatible
avec notre GPLv2+** mais on doit créditer Sameer Puri, nand2mario, et préserver
les notices.

[À VÉRIFIER] Confirmer la licence exacte des fichiers `hdmi2/*` quand on les
intègre.

---

## 7. Solver PLL Gowin rPLL

### Contraintes rPLL GW2A (à confirmer par datasheet UG290E)

- Référence : 27 MHz onboard ou autre PLL
- VCO range : typiquement 400-1200 MHz (à confirmer)
- IDIV (input divider) : 1-64
- FBDIV (feedback) : 1-64
- ODIV (output divider) : valeurs discrètes 2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128

### Formule de base

```
fout = (fin × FBDIV) / (IDIV × ODIV)

Contraintes :
  fvco = (fin × FBDIV) / IDIV  doit être dans VCO range
  fout doit être dans la plage d'output autorisée
```

### Algorithme du solver (porté de Groovy_MiSTer)

```c
// Pseudo-code, à adapter aux contraintes Gowin
int solvePLL_Gowin(double fout_target,
                   uint8_t *idiv, uint8_t *fbdiv, uint8_t *odiv) {
    double best_error = 1e9;
    int best_idiv, best_fbdiv, best_odiv;
    
    for (idiv = 1; idiv <= 64; idiv++) {
        for (odiv : ODIV_VALID_VALUES) {  // 2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128
            // fbdiv requis = fout × idiv × odiv / fref
            double fbdiv_real = fout_target * idiv * odiv / 27.0;
            int fbdiv_int = round(fbdiv_real);
            
            if (fbdiv_int < 1 || fbdiv_int > 64) continue;
            
            double fvco = 27.0 * fbdiv_int / idiv;
            if (fvco < 400.0 || fvco > 1200.0) continue;
            
            double fout_actual = fvco / odiv;
            double error = fabs(fout_actual - fout_target);
            
            if (error < best_error) {
                best_error = error;
                best_idiv = idiv;
                best_fbdiv = fbdiv_int;
                best_odiv = odiv;
            }
        }
    }
    
    *idiv = best_idiv;
    *fbdiv = best_fbdiv;
    *odiv = best_odiv;
    return (best_error < threshold) ? 0 : -1;
}
```

### Implémentation Verilog ou lookup table ?

[À DÉCIDER] Deux options :

**Option A : solver Verilog hardware**
- Pour : élégant, calcule à la volée pour toute pclk reçue
- Contre : code Verilog non trivial (divisions, recherche itérative), prend ~500-1000 LUT4, complexe à débugger

**Option B : lookup table (BRAM)**
- Pour : trivial, déterministe, debuggable. À la synthèse, on pré-calcule en C/Python une table {pclk_kHz → (idiv, fbdiv, odiv)} pour toutes les pclks entre 1 et 100 MHz par pas de 1 kHz = 100000 entrées × 3 bytes = 300 KB → ne rentre pas en BRAM mais en DDR3 oui
- Contre : précision limitée par la résolution de la LUT, occupe de la mémoire

**Option C : solver simple Verilog avec range limité**
- Pour : compromis. On contraint IDIV ≤ 4 (donne quasi toutes les modelines arcade), ce qui réduit l'espace de recherche à ~50 combinaisons à tester. Faisable en quelques cycles.
- Contre : moins de couverture théorique, mais en pratique suffisant pour arcade

**Recommandation initiale :** Option B en V1 (LUT en DDR3, simple), évolution vers Option C ou A si besoin.

### Plage de fréquences supportées

Cible : couvrir au minimum les pclks arcade typiques :
- Min : ~5 MHz (modes arcade très basse résolution)
- Max : ~80 MHz (modes 31 kHz super-résolution × 5)
- Pour TMDS : avec super-rez × N appliquée, pclk effective sortie = pclk_source × N, doit être ≥ 25 MHz

---

## 8. Stratégie super-résolution HDMI

### Problème

Le pixel clock HDMI minimum est 25 MHz (640×480@60). Les modelines arcade typiques sont 5-15 MHz. Donc on doit **multiplier horizontalement** par un facteur entier N pour atteindre la spec HDMI.

### Approche

Le PC envoie la modeline source (hActive=320, pClock=6.144 MHz par exemple). Le FPGA :
- Génère une modeline "stretchée" en sortie : hActive_out = hActive × N, pClock_out = pClock × N
- Recopie chaque pixel source N fois consécutivement (pixel doubling/tripling/etc.)

### Facteurs typiques

| pClock source | N | pClock HDMI | OK ? |
|---|---|---|---|
| 6.0 MHz | 4 | 24.0 MHz | ✗ (sous 25) |
| 6.0 MHz | 5 | 30.0 MHz | ✓ |
| 7.5 MHz | 4 | 30.0 MHz | ✓ |
| 13.5 MHz | 2 | 27.0 MHz | ✓ |
| 25.0 MHz | 1 | 25.0 MHz | ✓ |

### Choix de N côté FPGA

Le FPGA peut choisir N automatiquement :
```verilog
N = (pClock_source × 1 >= 25) ? 1 :
    (pClock_source × 2 >= 25) ? 2 :
    (pClock_source × 3 >= 25) ? 3 :
    (pClock_source × 4 >= 25) ? 4 :
    (pClock_source × 5 >= 25) ? 5 : 6;
```

### Inspiration de "ce_pix" dans Groovy_MiSTer

Psakhis utilise un concept similaire (`ce_pix` = 4, 6, 8, 12, 16) mais en interne (pour avoir une clock système >= 40 MHz pour le scaler). Notre N de super-résolution est différent : il s'applique à la sortie TMDS.

### TMDS et serializers Gowin (validé par tangcore/nestang)

- Pixel clock après super-rez : 25-80 MHz typiquement
- TMDS bit clock = 10 × pClock = 250-800 MHz
- Utilisation des **OSER10** du Gowin GW2A en mode DDR : la clock de
  sérialisation est `pClock × 5`, et chaque cycle sort 2 bits (DDR), donc le
  débit effectif est bien 10 × pClock. Cela évite d'avoir besoin d'une PLL à
  10× pClock (qui dépasserait souvent la plage VCO).
- Pour le clock TMDS lui-même : c'est `clk_pixel` direct (single-ended), passé
  dans un buffer `ELVDS_OBUF` pour générer la paire différentielle.
- Validé par tangcore/nestang à 720p (pclk 74.25 MHz, x5 = 371 MHz, OK pour
  Gowin GW2A en LVDS dédiés).

[À VÉRIFIER] Les pads HDMI du Tang Primer 20K Dock sont câblés sur des paires LVDS dédiées. Le mapping exact est dans le schématique du Dock.

---

## 9. Roadmap d'implémentation

### Phase 0 — Setup (rapide)

- [DÉCIDÉ] Toolchain Gowin EDA installée
- [DÉCIDÉ] Board branchée et reconnue USB
- [À FAIRE] Tester un exemple Sipeed (genre Hello World LED) pour valider le flow

### Phase 1 — Bases Verilog (apprentissage)

- LED qui clignote — comprendre `always`/`assign`/`<=`/`=`
- Compteur sur plusieurs LEDs — diviseurs d'horloge
- Première simulation iverilog + GTKWave

### Phase 2 — Bring-up HDMI (basé sur tangcore)

- Intégrer le module HDMI complet de `tangcore/nestang/src/hdmi2/`
- Reprendre `nes2hdmi.sv` comme exemple d'intégration (PLL + CLKDIV + serializer
  + ELVDS_OBUF + module hdmi)
- Sortie 720p @ 60 Hz fixe avec mire de test
- Tester en DVI_OUTPUT=1 d'abord (plus simple), puis HDMI complet
- Validation visuelle sur moniteur HDMI ou capture card

### Phase 3 — Pipeline vidéo paramétrable

- **Forker `hdmi.sv` pour rendre les paramètres de timing dynamiques** (signaux
  d'entrée plutôt que parameters statiques avec `generate case`)
- Tester avec plusieurs modelines hardcodées (320×240 stretched, 384×288, etc.)
- Sortie TMDS à pclk fixe d'abord (PLL non reconfigurable)
- Validation OSSC/capture card pour les modes non standards

### Phase 4 — Reconfig PLL dynamique

- Implémenter le wrapper rPLL Gowin avec reconfig dynamique
- Test : changer la pclk en runtime via UART ou switches
- Implémenter le séquenceur mode-change FSM (wait vblank → reconfig → re-lock → reprise)

### Phase 5 — Stack Ethernet

- Bring-up du PHY Ethernet 100M sur le Tang Primer Dock
- MAC RX hardware + parseur IPv4/UDP
- Tester avec un programme C qui envoie des paquets UDP raw, FPGA log via UART/ILA

### Phase 6 — Parsing protocole Groovy + premier blit raw

- Implémenter `groovy_packet_parser.v` pour les 8 commandes
- Gérer state machine isBlitting raw
- Premier blit RAW RGB888 from GroovyMAME → image affichée en HDMI super-rez

### Phase 7 — DDR3 et ring buffer

- Bring-up DDR3 Gowin
- Ring buffer frames en DDR3
- Découplage RX UDP / read pipeline TMDS

### Phase 8 — LZ4 hardware

- Port du `lz4.v` de Psakhis vers Gowin (adaptation BRAM 64-bit)
- Test avec `mister_compression lz4` côté PC
- Validation perf : couvre-t-on les modes 31 kHz ?

### Phase 9 — Interlaced

- Étendre le générateur de timing forké en Phase 3 pour gérer la demi-ligne et
  le field parity
- Étendre AVI InfoFrame pour annoncer interlaced au sink (scan_info)
- Gestion CMD_BLIT_FIELD_VSYNC avec field 0/1/2

### Phase 10 — Audio HDMI (grandement simplifié grâce à tangcore)

- **L'audio HDMI est déjà supporté par le module HDMI intégré en Phase 2** si on
  ne reste pas en DVI_OUTPUT=1
- Brancher `sound_l_out`/`sound_r_out` du module sound (Psakhis) sur
  `audio_sample_word[1:0]` du module HDMI
- Générer `clk_audio` par division depuis `clk_pixel` (5 lignes Verilog)
- CMD_AUDIO + streaming raw audio bytes côté parseur UDP
- Synchronisation audio/vidéo (gestion FIFO + clock domain crossing)
- [Option additionnelle, V1.x] : sortie I2S vers jack Dock en parallèle

### Phase 11 — Polish

- ACK robustesse
- frame_delta et frame_dup
- Gestion d'erreurs réseau
- Performance tuning

### Phase 12+ — V2 features

- Backend RLE/QOI optionnel (extension du protocole)
- Inputs PMOD (joystick arcade)
- Port sur un autre FPGA pour valider la portabilité

---

## 10. Questions ouvertes

### Q1 — Solver PLL : hardware Verilog, lookup table, ou hybride ?

Statut : penche vers LUT en DDR3 pré-calculée, à finaliser après bring-up rPLL.

### Q2 — Audio : HDMI data island ou jack 3.5mm Dock ?

**[RÉSOLU v0.2]** — HDMI data islands en V1, grâce à l'intégration du module HDMI
complet de tangcore (voir 6.5). Coût marginal négligeable (~5 lignes de Verilog
pour générer clk_audio + brancher les samples). Jack Dock devient optionnel
pour V1.x si demande utilisateur, mais pas prioritaire.

### Q3 — Inputs PMOD : V1 ou V2 ?

Statut : V2 plus probablement, sauf si on a un cas d'usage immédiat.

### Q4 — RGBA888 : implémenté en V1 ou skip ?

L'alpha n'a pas d'usage évident dans le code de Psakhis (à investiguer plus). Si pas critique, on peut commencer par RGB888 + RGB565 seulement et ajouter RGBA888 plus tard.

### Q5 — Mode-change : reconfig PLL via Verilog ou pré-cache de coefficients ?

Lié à Q1. Si on a une LUT pré-calculée, le mode change consiste juste à lire la LUT puis push les coefficients dans la rPLL.

### Q6 — UDP port GMC (32105) : à quoi sert-il ?

À investiguer dans le code de Psakhis. Probablement "Groovy MiSTer Cast" (MiSTerCast utility) ? Pas critique pour V1.

### Q7 — Frame delay automatique : reproduire le calcul côté FPGA ?

Le PC calcule vSync en fonction du ping. Le FPGA n'a rien à faire sauf renvoyer correctement les ACK avec le vCount actuel.

### Q8 — Stratégie de fork de hdmi.sv : maintenir un fork local ou patcher upstream ?

Le module HDMI de tangcore/sameer doit être étendu pour :
- Accepter timing en input dynamique (pas statique via VIDEO_ID_CODE)
- Supporter l'interlaced (field 0/1, demi-ligne, AVI scan_info)
- Supporter VIDEO_REFRESH_RATE dynamique pour calcul N audio

Options :
- (a) Fork local dans `rtl/generic/video/hdmi/`, maintenance autonome
- (b) Pull requests upstream chez sameer/hdl-util/hdmi puis nand2mario
- (c) Hybride : fork local d'abord, contribution upstream une fois stable

**Tendance :** option (c) — on fork pour V1, on contribue dès que c'est mature.

### Q9 — Support SystemVerilog dans Gowin EDA ?

Le module HDMI de tangcore est écrit en **SystemVerilog** (logic, generate avec
case, packed arrays, etc.). Gowin EDA a un support SV partiel. À tester en
Phase 2 : est-ce que tangcore se synthétise tel quel sur Tang Primer 20K, ou
faut-il convertir certaines parties en Verilog 2001 pur ?

[À VÉRIFIER] Sipeed liste explicitement les versions GowinEDA testées avec
tangcore — à corréler avec celles supportées sur Tang Primer 20K.

### Q10 — Forker tangcore complet vs cherry-pick le module hdmi2 seul ?

tangcore contient bien plus que le module HDMI : iosys BL616, picorv32, OSD,
USB, etc. La plupart n'est pas pertinent pour Groovy_Tang. Mais le pattern
BL616 ↔ FPGA est intéressant pour V2+ (configuration, debug, USB controllers).

**Tendance V1 :** cherry-pick `nestang/src/hdmi2/` + `nes2hdmi.sv` comme exemple
+ `nestang/src/pll/gowin_pll_hdmi.v` (à adapter pour reconfig dynamique).
Ignorer le reste pour l'instant.

---

## 11. Références

### Code de référence

- **Groovy_MiSTer** : https://github.com/psakhis/Groovy_MiSTer
  - `api/groovymister.{cpp,h}` : lib client C++
  - `hps_linux/src/support/groovy/groovy.cpp` : parseur UDP côté HPS
  - `hps_linux/src/support/groovy/pll.cpp` : solver PLL Cyclone V
  - `rtl/lz4.v` : décodeur LZ4 hardware
  - `rtl/vga.v` : module VGA out
  - `rtl/hps_ext.v` : interface HPS-FPGA (à NE PAS reprendre)

- **TangCore** : https://github.com/nand2mario/tangcore
  - `nestang/src/hdmi2/` : module HDMI complet pour Gowin (audio + InfoFrames + TERC4)
  - `nestang/src/nes2hdmi.sv` : exemple d'intégration HDMI sur Gowin
  - `nestang/src/pll/gowin_pll_hdmi.v` : PLL HDMI pré-configurée (à adapter en reconfigurable pour nous)
  - `nestang/src/iosys/iosys_bl616.v` : exemple d'usage du BL616 comme co-processeur (utile pour V2+)

- **sameer/hdl-util/hdmi** : https://github.com/hdl-util/hdmi
  - Source originale du module HDMI utilisé par tangcore
  - Référence open source standard pour HDMI sur FPGA
  - Multi-vendor : Xilinx, Gowin, Altera, Lattice (via `define)

### Toolchain et hardware

- **Gowin EDA** : toolchain officielle, education edition gratuite
- **Sipeed wiki Tang Primer 20K** : https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html
- **Datasheet GW2A** : Gowin UG289E (à récupérer pour spec rPLL exacte)

### Émetteurs PC compatibles (testables avec V1)

- **GroovyMAME** : https://github.com/antonioginer/GroovyMAME
- **emu4crt (Mednafen fork)** : https://github.com/psakhis/emu4crt
- **RetroArch fork** : https://github.com/antonioginer/RetroArch/tree/mister
- **86Box fork** : https://github.com/psakhis/86Box/tree/mister
- **MiSTerCast** : https://github.com/iequalshane/MiSTerCast

### Outils tests réseau

- Wireshark pour capture des paquets UDP entre PC et MiSTer (référence)
- tcpdump
- iperf3 (perf réseau brute)

---

## Notes de versions

**v0.2 (2026-06-05)** — Intégration des findings du projet `nand2mario/tangcore`.

Changements principaux :
- Section 6.5 ajoutée : module HDMI complet réutilisé depuis tangcore/nestang (basé sur sameer/hdl-util/hdmi).
- Section 5.6 (Audio) clarifiée : sortie via HDMI data islands en V1, jack Dock en option.
- Section 6.4 réduite : plusieurs modules (TMDS encoder, serializer, InfoFrames, audio packets) ne sont plus à écrire from scratch.
- Section 8 (TMDS Gowin) précisée : pattern pclk×5 en DDR validé par tangcore.
- Phases 2, 3, 9, 10 de la roadmap mises à jour pour exploiter le module HDMI tangcore.
- Q2 (audio jack vs HDMI) **résolue** : HDMI gagne grâce au coût marginal nul.
- Q8, Q9, Q10 ajoutées : stratégie de fork, support SystemVerilog Gowin EDA, ampleur du cherry-pick tangcore.
- Section 11 (Références) enrichie : tangcore + sameer/hdl-util/hdmi.

**v0.1 (2026-06-05)** — Première version du document, basée sur analyse complète du repo `psakhis/Groovy_MiSTer` lors d'une session interactive Subs / Claude.

Décisions clés actées :
- Compatibilité protocole stricte avec Groovy_MiSTer pour V1
- LZ4 hardware (port direct depuis lz4.v de Psakhis)
- Architecture en 4 couches RTL (vendor/board/core/generic)
- Solver PLL : à trancher (lookup table ou Verilog)
- RLE/QOI repoussés à V2+
- Licence GPLv2+

---

*Fin du document.*
