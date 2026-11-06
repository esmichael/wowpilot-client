<#
.SYNOPSIS
  WowPilot Sync — lê os prints do addon WowPilot, decodifica e envia ao site WowPilot.

.DESCRIPTION
  O addon desenha um código colorido no canto superior esquerdo da tela e tira um print (PNG).
  Este script vigia a pasta Screenshots do WoW a cada segundo, decodifica o código, envia os dados
  ao site (HTTPS, com o seu token) e apaga o print. Prints normais (sem código) não são tocados.
  Também envia o fim do WoWChatLog.txt quando ele muda (recupera o chat que o jogo esconde em combate).

  Primeira vez:   .\WowPilotSync.ps1 -Server https://wowpilot.exemplo.com -Token SEU_TOKEN
  Depois:         .\WowPilotSync.ps1          (usa a configuração salva em %LOCALAPPDATA%\WowPilot)

.PARAMETER Server
  Endereço do site (ex.: https://wowpilot.exemplo.com).
.PARAMETER Token
  Token gerado na página "Configurar" do site.
.PARAMETER WowPath
  Pasta _retail_ do WoW. Padrão: detectada pelo registro / C:\Program Files (x86)\World of Warcraft\_retail_
.PARAMETER KeepScreenshots
  Não apaga os prints depois de enviados.
.PARAMETER Once
  Processa o que houver na pasta e sai (teste).
.PARAMETER ConfigDir
  Onde guardar a configuração e os envios pendentes (padrão %LOCALAPPDATA%\WowPilot).
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Token,
    [string]$WowPath,
    [string]$ScreenshotDir,
    [switch]$KeepScreenshots,
    [switch]$NoChatLog,
    [switch]$Once,
    [int]$MaxAgeHours = 24,
    [string]$ConfigDir = (Join-Path $env:LOCALAPPDATA 'WowPilot')
)

$ErrorActionPreference = 'Stop'
$ClientVersion = '1.1.0'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$PendingDir = Join-Path $ConfigDir 'pendentes'
New-Item -ItemType Directory -Force -Path $ConfigDir, $PendingDir | Out-Null

$LogFile = Join-Path $ConfigDir 'WowPilotSync.log'
function Write-Log([string]$msg, [string]$color = 'Gray') {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd} {1}" -f (Get-Date), $line) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- configuração
$cfg = @{}
if (Test-Path $ConfigFile) {
    try { (Get-Content $ConfigFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
}
if ($Server) { $cfg.Server = $Server }
if ($Token) { $cfg.Token = $Token }
if ($WowPath) { $cfg.WowPath = $WowPath }
if (-not $cfg.Server -or -not $cfg.Token) {
    Write-Host 'Uso (primeira vez): .\WowPilotSync.ps1 -Server https://seu-site -Token SEU_TOKEN' -ForegroundColor Yellow
    Write-Host 'O token fica na página "Configurar" do site.'
    exit 1
}
$cfg.Server = ([string]$cfg.Server).TrimEnd('/')
if ($cfg.Server -notmatch '^https?://') { $cfg.Server = 'https://' + $cfg.Server }
# o PowerShell 5.1 tenta IPv6 (::1) primeiro em 'localhost' e trava quando o site só escuta IPv4
$cfg.Server = $cfg.Server -replace '^(https?://)localhost(?=[:/]|$)', '${1}127.0.0.1'

if (-not $cfg.WowPath) {
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                     'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($p -and (Test-Path $p)) { $cfg.WowPath = $p; break }
        } catch { }
    }
    if (-not $cfg.WowPath) { $cfg.WowPath = 'C:\Program Files (x86)\World of Warcraft\_retail_' }
}
$cfg.WowPath = ([string]$cfg.WowPath).TrimEnd('\')
if ((Split-Path $cfg.WowPath -Leaf) -ne '_retail_' -and (Test-Path (Join-Path $cfg.WowPath '_retail_'))) {
    $cfg.WowPath = Join-Path $cfg.WowPath '_retail_'
}
($cfg | ConvertTo-Json) | Set-Content -Path $ConfigFile -Encoding UTF8

$ShotDir = if ($ScreenshotDir) { $ScreenshotDir } else { Join-Path $cfg.WowPath 'Screenshots' }
# também as outras versões instaladas ao lado (_forever_, _classic_era_…), sem PTR/beta
$ShotDirs = @($ShotDir)
if (-not $ScreenshotDir) {
    $wowRoot = Split-Path $cfg.WowPath -Parent
    foreach ($d in (Get-ChildItem -Path $wowRoot -Directory -Filter '_*_' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($d.Name -match 'ptr|beta') { continue }
        $s = Join-Path $d.FullName 'Screenshots'
        if ($ShotDirs -notcontains $s) { $ShotDirs += $s }
    }
}
$ChatLog = Join-Path $cfg.WowPath 'Logs\WoWChatLog.txt'

# TLS 1.2 no Windows PowerShell 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- decodificador (C#)
$decoderSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;

namespace WowPilot {
public class Frame {
    public int Kind, Flags, Msg, Page, Total, Bits;
    public double Cell;
    public byte[] Chunk;
}

// Lê o código de pixels do WowPilotLive.lua (canto superior esquerdo do print).
// v3 (colorido): linha 1 = B em binário (células 1-8) + paleta/níveis medidos na própria imagem;
// v2 (preto e branco): bits linha a linha. Ver WowPilotLive.lua.
public class Decoder {
    const int DARK = 128;
    int w, h, stride;
    byte[] px; // BGR

    Decoder(Bitmap bmp) {
        w = Math.Min(bmp.Width, 2400); h = Math.Min(bmp.Height, 1200);
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try {
            stride = d.Stride;
            px = new byte[stride * h];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
        } finally { bmp.UnlockBits(d); }
    }

    int R(int x, int y) { return px[y * stride + x * 3 + 2]; }
    int G(int x, int y) { return px[y * stride + x * 3 + 1]; }
    int B(int x, int y) { return px[y * stride + x * 3]; }
    // mesma conversão do PIL ("L")
    int Gray(int x, int y) { return (R(x, y) * 299 + G(x, y) * 587 + B(x, y) * 114) / 1000; }

    double CellSize() {
        if (w < 64 || h < 4 || Gray(0, 0) >= DARK) return 0;
        int first = 0;
        while (first < Math.Min(w, 64) && Gray(first, 0) < DARK) first++;
        if (first < 1 || first > 32) return 0;
        int y = Math.Min(h - 1, first / 2);
        List<int> edges = new List<int>();
        bool prev = Gray(0, y) < DARK;
        int lim = Math.Min(w, first * 320);
        for (int x = 1; x < lim; x++) {
            bool cur = Gray(x, y) < DARK;
            if (cur == prev) continue;
            prev = cur;
            double c = edges.Count > 0 ? (double)edges[edges.Count - 1] / edges.Count : first;
            if (Math.Abs(x - (edges.Count + 1) * c) > Math.Max(c * 0.5, 1.0)) break;
            edges.Add(x);
            if (edges.Count >= 254) break;
        }
        if (edges.Count < 16) return 0;
        double cell = (double)edges[edges.Count - 1] / edges.Count;
        return Math.Abs(cell - Math.Round(cell)) < 0.05 ? Math.Round(cell) : cell;
    }

    // ---------- preto e branco
    int Bit(double c, int row, int col) {
        int r = Math.Max(0, (int)(c / 3));
        int cx = (int)((col + 0.5) * c), cy = (int)((row + 0.5) * c);
        if (cx >= w || cy >= h) throw new IndexOutOfRangeException();
        long total = 0; int n = 0;
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++) {
                total += Gray(Math.Min(w - 1, Math.Max(0, cx + dx)), Math.Min(h - 1, Math.Max(0, cy + dy)));
                n++;
            }
        return (double)total / n < DARK ? 1 : 0;
    }

    byte[] BwBytes(double c, int cols, int start, int count) {
        int width = cols - 1;
        byte[] o = new byte[count];
        for (int i = 0; i < count; i++) {
            int b = 0;
            for (int k = 0; k < 8; k++) {
                int idx = (start + i) * 8 + k;
                b = (b << 1) | Bit(c, 1 + idx / width, 1 + idx % width);
            }
            o[i] = (byte)b;
        }
        return o;
    }

    // ---------- colorido
    double[] Sample(double c, int row, int col) {
        int r = Math.Max(0, (int)(c / 4));
        int cx = (int)((col + 0.5) * c), cy = (int)((row + 0.5) * c);
        if (cx >= w || cy >= h) throw new IndexOutOfRangeException();
        double sr = 0, sg = 0, sb = 0; int n = 0;
        for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++) {
                int x = Math.Min(w - 1, Math.Max(0, cx + dx)), y = Math.Min(h - 1, Math.Max(0, cy + dy));
                sr += R(x, y); sg += G(x, y); sb += B(x, y); n++;
            }
        return new double[] { sr / n, sg / n, sb / n };
    }

    class ColorReader {
        Decoder d; double c; int bpc, cols;
        double[][] palette; double[][] levels; int L, k;
        Dictionary<int, int> cache = new Dictionary<int, int>();
        Dictionary<int, int> cells = new Dictionary<int, int>();

        public ColorReader(Decoder d, double c, int bpc, int cols) {
            this.d = d; this.c = c; this.bpc = bpc; this.cols = cols;
            if (bpc <= 6) {
                palette = new double[1 << bpc][];
                for (int i = 0; i < palette.Length; i++) palette[i] = d.Sample(c, 1, 9 + i);
            } else {
                k = bpc / 3; L = 1 << k;
                levels = new double[3][];
                for (int ch = 0; ch < 3; ch++) {
                    levels[ch] = new double[L];
                    for (int lv = 0; lv < L; lv++) levels[ch][lv] = d.Sample(c, 1, 9 + ch * L + lv)[ch];
                }
            }
        }

        int Nearest(int ch, double v) {
            int best = 0; double bd = double.MaxValue;
            for (int lv = 0; lv < L; lv++) { double e = Math.Abs(v - levels[ch][lv]); if (e < bd) { bd = e; best = lv; } }
            return best;
        }

        int Classify(double[] p) {
            int key = ((int)p[0] << 16) | ((int)p[1] << 8) | (int)p[2];
            int v;
            if (cache.TryGetValue(key, out v)) return v;
            if (palette != null) {
                double bd = double.MaxValue;
                for (int i = 0; i < palette.Length; i++) {
                    double dr = p[0] - palette[i][0], dg = p[1] - palette[i][1], db = p[2] - palette[i][2];
                    double e = dr * dr + dg * dg + db * db;
                    if (e < bd) { bd = e; v = i; }
                }
            } else {
                v = (Nearest(0, p[0]) << (2 * k)) | (Nearest(1, p[1]) << k) | Nearest(2, p[2]);
            }
            cache[key] = v;
            return v;
        }

        int Cell(int idx) {
            int v;
            if (!cells.TryGetValue(idx, out v)) {
                int width = cols - 1;
                v = Classify(d.Sample(c, 2 + idx / width, 1 + idx % width));
                cells[idx] = v;
            }
            return v;
        }

        public byte[] Read(int start, int count) {
            byte[] o = new byte[count];
            for (int i = 0; i < count; i++) {
                int b = 0;
                for (int j = 0; j < 8; j++) {
                    int bitpos = (start + i) * 8 + j;
                    int v = Cell(bitpos / bpc);
                    b = (b << 1) | ((v >> (bpc - 1 - bitpos % bpc)) & 1);
                }
                o[i] = (byte)b;
            }
            return o;
        }
    }

    public static uint Adler32(byte[] data) {
        uint a = 1, b = 0;
        foreach (byte x in data) { a = (a + x) % 65521; b = (b + a) % 65521; }
        return (b << 16) | a;
    }

    static int U16(byte[] b, int i) { return (b[i] << 8) | b[i + 1]; }
    static uint U32(byte[] b, int i) { return ((uint)b[i] << 24) | ((uint)b[i + 1] << 16) | ((uint)b[i + 2] << 8) | b[i + 3]; }

    Frame DecodeColor(double c, int bpc) {
        try {
            byte[] head = new ColorReader(this, c, bpc, 255).Read(0, 4);
            if (head[0] != 'W' || head[1] != 'P' || head[2] != 3) return null;
            ColorReader rd = new ColorReader(this, c, bpc, head[3]);
            head = rd.Read(0, 16);
            Frame f = new Frame();
            f.Kind = head[4]; f.Flags = head[5]; f.Msg = U16(head, 6); f.Page = head[8]; f.Total = head[9];
            f.Bits = bpc; f.Cell = c;
            int size = U16(head, 10);
            uint sum = U32(head, 12);
            f.Chunk = rd.Read(16, size);
            if (Adler32(f.Chunk) != sum || f.Page >= Math.Max(1, f.Total)) return null;
            return f;
        } catch (IndexOutOfRangeException) { return null; }
    }

    Frame Decode() {
        double c = CellSize();
        if (c <= 0) return null;
        try {
            int mode = BwBytes(c, 255, 0, 1)[0];
            if (mode == 3 || mode == 6 || mode == 9 || mode == 12) return DecodeColor(c, mode);
            byte[] head = BwBytes(c, 128, 0, 4);
            if (head[0] != 'W' || head[1] != 'P' || head[2] != 2) return null;
            int cols = head[3];
            head = BwBytes(c, cols, 0, 16);
            Frame f = new Frame();
            f.Kind = head[4]; f.Flags = head[5]; f.Msg = U16(head, 6); f.Page = head[8]; f.Total = head[9];
            f.Bits = 1; f.Cell = c;
            int size = U16(head, 10);
            uint sum = U32(head, 12);
            f.Chunk = BwBytes(c, cols, 16, size);
            if (Adler32(f.Chunk) != sum || f.Page >= Math.Max(1, f.Total)) return null;
            return f;
        } catch (IndexOutOfRangeException) { return null; }
    }

    // null = não é um print do WowPilot
    public static Frame DecodeFile(string path) {
        byte[] bytes = File.ReadAllBytes(path);  // não prende o arquivo (para poder apagar depois)
        using (MemoryStream ms = new MemoryStream(bytes))
        using (Bitmap bmp = new Bitmap(ms)) {
            return new Decoder(bmp).Decode();
        }
    }

    public static byte[] Decompress(byte[] data) {
        int skip = 0;
        if (data.Length > 2 && (data[0] & 0x0F) == 8 && ((data[0] << 8) | data[1]) % 31 == 0) skip = 2; // zlib
        using (MemoryStream src = new MemoryStream(data, skip, data.Length - skip))
        using (MemoryStream dst = new MemoryStream()) {
            if (data.Length > 2 && data[0] == 0x1f && data[1] == 0x8b) {
                using (GZipStream z = new GZipStream(src, CompressionMode.Decompress)) z.CopyTo(dst);
            } else {
                using (DeflateStream z = new DeflateStream(src, CompressionMode.Decompress)) z.CopyTo(dst);
            }
            return dst.ToArray();
        }
    }

    public static byte[] Gzip(byte[] data) {
        using (MemoryStream dst = new MemoryStream()) {
            using (GZipStream z = new GZipStream(dst, CompressionLevel.Optimal)) z.Write(data, 0, data.Length);
            return dst.ToArray();
        }
    }
}

// Junta as páginas de uma mensagem (prints em sequência).
public class Assembler {
    class Entry { public DateTime At; public Dictionary<int, byte[]> Pages = new Dictionary<int, byte[]>(); }
    Dictionary<string, Entry> partial = new Dictionary<string, Entry>();

    // devolve os dados completos (descomprimidos) ou null se ainda faltam páginas
    public byte[] Add(Frame f) {
        List<string> old = new List<string>();
        foreach (KeyValuePair<string, Entry> kv in partial) if ((DateTime.Now - kv.Value.At).TotalSeconds > 180) old.Add(kv.Key);
        foreach (string k in old) partial.Remove(k);
        byte[] data;
        if (f.Total <= 1) {
            data = f.Chunk;
        } else {
            string key = f.Msg + "/" + f.Kind + "/" + f.Total + "/" + f.Flags;
            Entry e;
            if (!partial.TryGetValue(key, out e)) { e = new Entry(); e.At = DateTime.Now; partial[key] = e; }
            e.Pages[f.Page] = f.Chunk;
            if (e.Pages.Count < f.Total) return null;
            partial.Remove(key);
            using (MemoryStream ms = new MemoryStream()) {
                for (int i = 0; i < f.Total; i++) ms.Write(e.Pages[i], 0, e.Pages[i].Length);
                data = ms.ToArray();
            }
        }
        return (f.Flags & 1) != 0 ? Decoder.Decompress(data) : data;
    }

    public int Waiting { get { return partial.Count; } }
}
}
'@

if (-not ('WowPilot.Decoder' -as [type])) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -TypeDefinition $decoderSource -ReferencedAssemblies System.Drawing.Common, System.Drawing.Primitives, System.IO.Compression, System.Collections, System.Runtime.InteropServices
    } else {
        Add-Type -TypeDefinition $decoderSource -ReferencedAssemblies System.Drawing
    }
}

# ---------------------------------------------------------------- envio
$Headers = @{ 'Authorization' = "Token $($cfg.Token)"; 'X-WowPilot-Client' = "ps1/$ClientVersion" }

function Send-Data([string]$path, [byte[]]$body, [string]$contentType) {
    $gz = [WowPilot.Decoder]::Gzip($body)
    $h = $Headers.Clone()
    $h['Content-Encoding'] = 'gzip'
    $r = Invoke-WebRequest -Uri ($cfg.Server + $path) -Method Post -Headers $h -ContentType $contentType -Body $gz -UseBasicParsing -TimeoutSec 30
    return $r.Content
}

function Save-Pending([byte[]]$data) {
    $name = '{0:yyyyMMdd_HHmmss_fff}.json' -f (Get-Date)
    [IO.File]::WriteAllBytes((Join-Path $PendingDir $name), $data)
}

function Send-Snapshot([byte[]]$data) {
    try {
        $res = Send-Data '/api/ingest' $data 'application/json; charset=utf-8'
        return $true
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 401 -or $status -eq 403) {
            Write-Log "token recusado pelo site ($status) — gere outro na página Configurar" 'Red'
        } elseif ($status -ge 400 -and $status -lt 500) {
            Write-Log "o site recusou os dados ($status): $($_.Exception.Message)" 'Red'
            return $true  # não adianta reenviar
        } else {
            Write-Log "site indisponível ($($_.Exception.Message)) — guardado para reenviar" 'Yellow'
        }
        return $false
    }
}

function Send-PendingFiles {
    foreach ($f in (Get-ChildItem -Path $PendingDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (Send-Snapshot ([IO.File]::ReadAllBytes($f.FullName))) {
            Remove-Item $f.FullName -Force
            Write-Log "pendente $($f.Name) enviado" 'Green'
        } else { break }
    }
}

# ---------------------------------------------------------------- laço principal
$assembler = New-Object WowPilot.Assembler
$seen = @{}          # nome → assinatura (tempo|tamanho) ou 'done'
$sent = 0
$started = Get-Date
$lastChat = $null
if (Test-Path $ChatLog) { $lastChat = (Get-Item $ChatLog).LastWriteTimeUtc }  # só manda quando mudar
$lastPendingTry = [DateTime]::MinValue

if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force }
Write-Host ''
Write-Host "WowPilot Sync $ClientVersion" -ForegroundColor Cyan
Write-Log "site: $($cfg.Server)"
Write-Log "prints: $($ShotDirs -join ' · ')"
if (-not (Test-Path $ShotDir)) { Write-Log 'a pasta Screenshots ainda não existe — esperando o primeiro print' 'Yellow' }
try {
    $who = Invoke-RestMethod -Uri ($cfg.Server + '/api/whoami') -Headers $Headers -UseBasicParsing -TimeoutSec 15
    Write-Log "conectado como $($who.user)" 'Green'
} catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -eq 401 -or $status -eq 403) { Write-Log 'token inválido — gere outro na página Configurar do site' 'Red'; exit 2 }
    Write-Log "não consegui falar com o site agora ($($_.Exception.Message)); sigo tentando" 'Yellow'
}
Write-Log 'vigiando… (Ctrl+C para sair)'

while ($true) {
    foreach ($dir in $ShotDirs) {
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.png' } | Sort-Object Name
        foreach ($f in $files) {
            $sig = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
            $prev = $seen[$f.FullName]
            if ($prev -eq 'done') { continue }
            if ($f.LastWriteTime -lt (Get-Date).AddHours(-$MaxAgeHours)) { $seen[$f.FullName] = 'done'; continue }
            if ($prev -ne $sig -and -not $Once) { $seen[$f.FullName] = $sig; continue }   # espera o jogo terminar de gravar
            $seen[$f.FullName] = 'done'
            $frame = $null
            try { $frame = [WowPilot.Decoder]::DecodeFile($f.FullName) } catch { Write-Log "erro lendo $($f.Name): $($_.Exception.Message)" 'Yellow' }
            if (-not $frame) { continue }   # print normal
            try {
                $data = $assembler.Add($frame)
            } catch {
                Write-Log "mensagem inválida em $($f.Name): $($_.Exception.Message)" 'Yellow'
                $data = $null
            }
            if (-not $KeepScreenshots) { try { Remove-Item $f.FullName -Force } catch { Write-Log "não apaguei $($f.Name)" 'Yellow' } }
            if ($null -eq $data) {
                if ($frame.Total -gt 1) { Write-Log ("página {0}/{1} ({2})" -f ($frame.Page + 1), $frame.Total, $f.Name) }
                continue
            }
            if ($frame.Kind -ne 3) { continue }
            if (Send-Snapshot $data) {
                $sent++
                Write-Log ("enviado #{0}: {1:N1} KB ({2} cores, {3} print(s))" -f $sent, ($data.Length / 1KB), [math]::Pow(2, $frame.Bits), [math]::Max(1, $frame.Total)) 'Green'
            } else {
                Save-Pending $data
            }
        }
    }

    # chat log do jogo (gravado pelo WoW no logout): manda o fim do arquivo quando muda
    if (-not $NoChatLog -and (Test-Path $ChatLog)) {
        $mt = (Get-Item $ChatLog).LastWriteTimeUtc
        if ($mt -ne $lastChat -and ((Get-Date).ToUniversalTime() - $mt).TotalSeconds -gt 3) {
            $lastChat = $mt
            try {
                $fs = [IO.File]::Open($ChatLog, 'Open', 'Read', 'ReadWrite')
                try {
                    $n = [Math]::Min($fs.Length, 1MB)
                    [void]$fs.Seek(-$n, 'End')
                    $buf = New-Object byte[] $n
                    [void]$fs.Read($buf, 0, $n)
                } finally { $fs.Close() }
                $res = Send-Data '/api/chatlog' $buf 'text/plain; charset=utf-8'
                Write-Log "chat log enviado ($([math]::Round($n / 1KB)) KB)" 'Green'
            } catch { Write-Log "chat log: $($_.Exception.Message)" 'Yellow' }
        }
    }

    if (((Get-Date) - $lastPendingTry).TotalSeconds -ge 30) {
        $lastPendingTry = Get-Date
        Send-PendingFiles
    }
    if ($Once) { break }
    Start-Sleep -Seconds 1
}
