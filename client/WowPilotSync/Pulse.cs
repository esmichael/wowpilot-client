// Pulso: lê a faixa do WowPilotPulse.lua (canto superior esquerdo da janela do jogo) direto da tela, sem print, e manda
// ao site (/api/pulse) — posição, direção, vida e estado a cada segundo. Ver WowPilotPulse.lua para o formato.
// C# 5 (csc.exe do .NET Framework 4).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace WowPilot {

public class PulseData {
    public int Seq, Ui, Facing, Hp, Flags, Level, Deaths;
    public long T;
    public uint Char;
    public double X, Y, A, B, C;

    static string N(double v) { return v.ToString("0.###", CultureInfo.InvariantCulture); }

    public string Json() {
        StringBuilder s = new StringBuilder("{");
        s.Append("\"v\":1,\"seq\":").Append(Seq).Append(",\"t\":").Append(T).Append(",\"char\":").Append(Char);
        if ((Flags & 128) != 0) {
            s.Append(",\"ui\":").Append(Ui).Append(",\"x\":").Append(N(X)).Append(",\"y\":").Append(N(Y));
            s.Append(",\"pos\":[").Append(N(A)).Append(",").Append(N(B)).Append(",").Append(N(C)).Append("]");
        }
        if ((Flags & 64) != 0) s.Append(",\"facing\":").Append(N(Facing / 256.0 * 2 * Math.PI));
        if (Hp != 255) s.Append(",\"hp\":").Append(Hp);
        s.Append(",\"flags\":").Append(Flags).Append(",\"lvl\":").Append(Level).Append(",\"deaths\":").Append(Deaths);
        return s.Append("}").ToString();
    }
}

public static class Pulse {
    public const int CELL = 2, COLS = 56, ROWS = 2;

    // faixa a partir de (ox, oy) do bitmap (px físicos); null se não houver uma válida ali
    public static PulseData Decode(Bitmap bmp, int ox, int oy) {
        if (bmp.Width < ox + COLS * CELL || bmp.Height < oy + ROWS * CELL) return null;
        byte[] bytes = new byte[ROWS * COLS * 3 / 8];
        int bit = 0;
        for (int r = 0; r < ROWS; r++) {
            for (int c = 0; c < COLS; c++) {
                int sr = 0, sg = 0, sb = 0;
                for (int dy = 0; dy < CELL; dy++) for (int dx = 0; dx < CELL; dx++) {
                    Color p = bmp.GetPixel(ox + c * CELL + dx, oy + r * CELL + dy);
                    sr += p.R; sg += p.G; sb += p.B;
                }
                int n = CELL * CELL;
                foreach (int v in new[] { sr / n, sg / n, sb / n }) {
                    if (bit / 8 < bytes.Length && v >= 128) bytes[bit / 8] |= (byte)(0x80 >> (bit % 8));
                    bit++;
                }
            }
        }
        if (bytes[0] != (byte)'W' || bytes[1] != (byte)'Q' || bytes[2] != 1) return null;
        int len = bytes[3];
        if (len != 34 || 4 + len + 4 > bytes.Length) return null;
        byte[] content = new byte[len];
        Array.Copy(bytes, 4, content, 0, len);
        if (Decoder.Adler32(content) != U32(bytes, 4 + len)) return null;
        PulseData d = new PulseData();
        d.Seq = U16(content, 0);
        d.T = U32(content, 2);
        d.Char = U32(content, 6);
        d.Ui = U16(content, 10);
        d.X = U16(content, 12) / 65535.0 * 100;
        d.Y = U16(content, 14) / 65535.0 * 100;
        d.A = S32(content, 16) / 10.0;
        d.B = S32(content, 20) / 10.0;
        d.C = S32(content, 24) / 10.0;
        d.Facing = content[28];
        d.Hp = content[29];
        d.Flags = content[30];
        d.Level = content[31];
        d.Deaths = U16(content, 32);
        return d;
    }

    static int U16(byte[] b, int i) { return (b[i] << 8) | b[i + 1]; }
    static uint U32(byte[] b, int i) { return ((uint)b[i] << 24) | ((uint)b[i + 1] << 16) | ((uint)b[i + 2] << 8) | b[i + 3]; }
    static int S32(byte[] b, int i) { return unchecked((int)U32(b, i)); }

    // ---------------------------------------------------------------- tela
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);

    // janelas do jogo visíveis → canto da área do jogo na tela. Classe "waApplication Window" no cliente atual (Retail e
    // Forever, testado 09/11/2026); "GxWindowClass" nos antigos; o título "World of Warcraft" cobre o resto.
    static List<Rectangle> GameOrigins() {
        var found = new List<Rectangle>();
        EnumWindows(delegate(IntPtr h, IntPtr _) {
            StringBuilder cls = new StringBuilder(64);
            GetClassName(h, cls, cls.Capacity);
            StringBuilder title = new StringBuilder(64);
            GetWindowText(h, title, title.Capacity);
            string c = cls.ToString();
            bool game = c == "waApplication Window" || c == "GxWindowClass" || title.ToString().StartsWith("World of Warcraft");
            if (!game || !IsWindowVisible(h) || IsIconic(h)) return true;
            RECT r;
            if (!GetClientRect(h, out r) || r.Right < COLS * CELL || r.Bottom < ROWS * CELL) return true;
            POINT p = new POINT();
            if (ClientToScreen(h, ref p)) found.Add(new Rectangle(p.X, p.Y, r.Right, r.Bottom));
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // o código do WowPilotLive no modo tela (addon WowPilotApp): 255 colunas × 2 px, até 40 linhas × 2 px, no mesmo
    // canto da faixa (por cima dela enquanto está à vista)
    public const int CODE_W = 640, CODE_H = 120;

    // a faixa de cada janela do jogo à vista (encoberta, minimizada ou em tela cheia exclusiva: nada). Com `codes`, a
    // captura cobre também o código e, sem faixa no canto (o código está por cima), tenta lê-lo.
    public static List<PulseData> ReadScreen(List<Frame> codes) {
        var out_ = new List<PulseData>();
        foreach (Rectangle o in GameOrigins()) {
            try {
                int w = codes != null ? Math.Min(CODE_W, o.Width) : COLS * CELL;
                int h = codes != null ? Math.Min(CODE_H, o.Height) : ROWS * CELL;
                using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
                    using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(o.X, o.Y, 0, 0, bmp.Size);
                    Read(bmp, out_, codes);
                }
            } catch { }
        }
        return out_;
    }

    // o canto capturado: a faixa; sem ela (o código está por cima), o código
    static void Read(Bitmap bmp, List<PulseData> pulses, List<Frame> codes) {
        PulseData d = Decode(bmp, 0, 0);
        if (d != null) { pulses.Add(d); return; }
        if (codes == null) return;
        Frame f = Decoder.DecodeBitmap(bmp);
        if (f != null) codes.Add(f);
    }

    // teste: o mesmo pedaço que o app copia da tela (CODE_W × CODE_H no canto), lido de uma imagem
    public static int ScreenPngCli(string path) {
        using (Bitmap src = new Bitmap(path))
        using (Bitmap bmp = src.Clone(new Rectangle(0, 0, Math.Min(CODE_W, src.Width), Math.Min(CODE_H, src.Height)), PixelFormat.Format24bppRgb)) {
            var pulses = new List<PulseData>();
            var codes = new List<Frame>();
            Read(bmp, pulses, codes);
            foreach (PulseData p in pulses) Console.WriteLine("pulso " + p.Json());
            foreach (Frame f in codes)
                Console.WriteLine("codigo msg=" + f.Msg + " pagina=" + f.Page + "/" + f.Total + " tipo=" + f.Kind + " bytes=" + f.Chunk.Length
                    + " adler=" + Decoder.Adler32(f.Chunk));
            return pulses.Count + codes.Count > 0 ? 0 : 1;
        }
    }

    // teste: decodifica a faixa no canto de uma imagem
    public static int DecodePngCli(string path) {
        using (Bitmap bmp = new Bitmap(path)) {
            PulseData d = Decode(bmp, 0, 0);
            Console.WriteLine(d != null ? d.Json() : "sem pulso");
            return d != null ? 0 : 1;
        }
    }
}
}
