// Decodificador do código de pixels e busca das instalações do WoW — mesma fonte embutida em client/WowPilotSync.ps1 (manter as duas iguais;
// tests/test_live_decode.py confere). C# 5: compila com o csc.exe do .NET Framework 4.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using Microsoft.Win32;

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

    // Tira uma chave do objeto JSON principal ({"a":1,"chat":[...],"b":2} -> {"a":1,"b":2}); o resto fica igual,
    // byte a byte. Sem a chave, devolve o mesmo array.
    public static byte[] DropKey(byte[] json, string key) {
        string s = System.Text.Encoding.UTF8.GetString(json), want = "\"" + key + "\"";
        int depth = 0;
        for (int i = 0; i < s.Length; i++) {
            char ch = s[i];
            if (ch == '"') {
                int end = StringEnd(s, i);
                if (depth == 1 && end - i + 1 == want.Length && string.CompareOrdinal(s, i, want, 0, want.Length) == 0) {
                    int j = end + 1;
                    while (j < s.Length && char.IsWhiteSpace(s[j])) j++;
                    if (j < s.Length && s[j] == ':') {
                        int k = ValueEnd(s, j + 1), from = i, to = k;
                        if (k < s.Length && s[k] == ',') to = k + 1;
                        else {
                            int b = i - 1;
                            while (b >= 0 && char.IsWhiteSpace(s[b])) b--;
                            if (b >= 0 && s[b] == ',') from = b;
                        }
                        return System.Text.Encoding.UTF8.GetBytes(s.Remove(from, to - from));
                    }
                }
                i = end;
            } else if (ch == '{' || ch == '[') depth++;
            else if (ch == '}' || ch == ']') depth--;
        }
        return json;
    }

    static int StringEnd(string s, int i) {
        for (int j = i + 1; j < s.Length; j++) {
            if (s[j] == '\\') j++;
            else if (s[j] == '"') return j;
        }
        return s.Length - 1;
    }

    // fim de um valor JSON que começa em i: posição da vírgula ou do fecha-chaves que vem depois dele
    static int ValueEnd(string s, int i) {
        int depth = 0;
        for (int j = i; j < s.Length; j++) {
            char ch = s[j];
            if (ch == '"') j = StringEnd(s, j);
            else if (ch == '{' || ch == '[') depth++;
            else if (ch == '}' || ch == ']') { if (depth == 0) return j; depth--; }
            else if (ch == ',' && depth == 0) return j;
        }
        return s.Length;
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
// Instalações do WoW neste PC. Cada variação (Retail, Forever, Classic, PTR…) é uma pasta _nome_ dentro da pasta
// "World of Warcraft", com um .flavor.info que diz o produto ("wow", "wowf"…). Pastas que sobraram de variações
// desinstaladas não têm esse arquivo nem o Wow*.exe e ficam de fora.
public class Flavor {
    public string Dir, Product, Name;
    public string Screenshots { get { return Path.Combine(Dir, "Screenshots"); } }
    public string ChatLog { get { return Path.Combine(Dir, @"Logs\WoWChatLog.txt"); } }
}

public static class WowInstall {
    static readonly Dictionary<string, string> Names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
        { "wow", "Retail" }, { "wowf", "WoW: Forever" }, { "wowt", "PTR" }, { "wowxptr", "PTR 2" }, { "wow_beta", "Beta" },
        { "wow_classic", "Classic" }, { "wow_classic_era", "Classic Era" }, { "wow_classic_ptr", "Classic PTR" },
        { "wow_classic_beta", "Classic Beta" }, { "wow_classic_era_ptr", "Classic Era PTR" } };

    static readonly string[] Common = { @"Program Files (x86)\World of Warcraft", @"Program Files\World of Warcraft",
        @"World of Warcraft", @"Games\World of Warcraft", @"Jogos\World of Warcraft", @"Blizzard\World of Warcraft",
        @"Battle.net\World of Warcraft", @"Blizzard Games\World of Warcraft" };

    // variações encontradas: Retail primeiro, depois Forever, depois o resto em ordem alfabética.
    // "chosen" (opcional) é a pasta escolhida pelo usuário; se não tiver nenhuma variação, a busca automática vale.
    public static List<Flavor> Find(string chosen) {
        var found = new List<Flavor>();
        if (!string.IsNullOrEmpty(chosen)) AddFlavors(found, RootOf(chosen));
        if (found.Count == 0) foreach (string root in Roots()) AddFlavors(found, root);
        found.Sort((a, b) => {
            int r = Rank(a).CompareTo(Rank(b));
            return r != 0 ? r : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });
        return found;
    }

    public static string Describe(List<Flavor> flavors) {
        var names = new List<string>();
        foreach (Flavor f in flavors) names.Add(f.Name);
        return string.Join(" · ", names.ToArray());
    }

    // pasta de uma variação (_retail_) ou de dentro dela → a pasta "World of Warcraft" que contém as variações
    public static string RootOf(string p) {
        p = (p ?? "").Trim().TrimEnd('\\', '/');
        if (p.Length == 0) return p;
        try { if (IsFlavor(p)) return Path.GetDirectoryName(p); } catch { }
        return p;
    }

    static int Rank(Flavor f) {
        if (string.Equals(f.Product, "wow", StringComparison.OrdinalIgnoreCase)) return 0;
        if (string.Equals(f.Product, "wowf", StringComparison.OrdinalIgnoreCase)) return 1;
        return 2;
    }

    static bool IsFlavor(string dir) {
        return File.Exists(Path.Combine(dir, ".flavor.info")) || Directory.GetFiles(dir, "Wow*.exe").Length > 0;
    }

    static void AddFlavors(List<Flavor> found, string root) {
        try {
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) return;
            foreach (string dir in Directory.GetDirectories(root, "_*_")) {
                if (!IsFlavor(dir)) continue;
                bool dup = false;
                foreach (Flavor f in found) if (string.Equals(f.Dir, dir, StringComparison.OrdinalIgnoreCase)) dup = true;
                if (dup) continue;
                string product = ReadProduct(dir), folder = Path.GetFileName(dir), name;
                if (product == null || !Names.TryGetValue(product, out name)) name = Pretty(folder);
                found.Add(new Flavor { Dir = dir, Product = product ?? folder.Trim('_'), Name = name });
            }
        } catch { }
    }

    // .flavor.info: "Product Flavor!STRING:0" e, na linha seguinte, o código do produto
    static string ReadProduct(string dir) {
        try {
            string[] lines = File.ReadAllLines(Path.Combine(dir, ".flavor.info"));
            for (int i = 1; i < lines.Length; i++) if (lines[i].Trim().Length > 0) return lines[i].Trim();
        } catch { }
        return null;
    }

    static string Pretty(string folder) {   // "_classic_era_" → "Classic era"
        string s = folder.Trim('_').Replace('_', ' ');
        return s.Length == 0 ? folder : char.ToUpperInvariant(s[0]) + s.Substring(1);
    }

    // onde procurar: o que o instalador do Battle.net registrou e os caminhos comuns em todos os discos
    static List<string> Roots() {
        var roots = new List<string>();
        foreach (string view in new[] { @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                                        @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" }) {
            try {
                using (RegistryKey un = Registry.LocalMachine.OpenSubKey(view)) {
                    if (un == null) continue;
                    foreach (string name in un.GetSubKeyNames()) {
                        using (RegistryKey k = un.OpenSubKey(name)) {
                            string display = k == null ? null : k.GetValue("DisplayName") as string;
                            if (display == null || !display.StartsWith("World of Warcraft", StringComparison.OrdinalIgnoreCase)) continue;
                            AddRoot(roots, k.GetValue("InstallLocation") as string);
                        }
                    }
                }
            } catch { }
        }
        foreach (string key in new[] { @"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                                       @"SOFTWARE\Blizzard Entertainment\World of Warcraft" }) {
            try {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(key))
                    if (k != null) AddRoot(roots, k.GetValue("InstallPath") as string);
            } catch { }
        }
        try {
            foreach (DriveInfo d in DriveInfo.GetDrives()) {
                if (d.DriveType != DriveType.Fixed || !d.IsReady) continue;
                foreach (string c in Common) AddRoot(roots, Path.Combine(d.RootDirectory.FullName, c));
            }
        } catch { }
        return roots;
    }

    static void AddRoot(List<string> roots, string p) {
        string root = RootOf(p);
        if (root.Length == 0 || !Directory.Exists(root)) return;
        foreach (string r in roots) if (string.Equals(r, root, StringComparison.OrdinalIgnoreCase)) return;
        roots.Add(root);
    }
}
}
