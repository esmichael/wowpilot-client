// Decodificador do código de pixels — mesma fonte embutida em client/WowPilotSync.ps1 (manter as duas iguais;
// tests/test_live_decode.py confere). C# 5: compila com o csc.exe do .NET Framework 4.
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
