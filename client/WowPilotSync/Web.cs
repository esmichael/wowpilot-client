// Site dentro do app (WebView2, o motor do Edge que já vem no Windows 10/11): a mesma página do navegador, logada pelo
// token do programa (/app/entrar, token no cabeçalho) e depois pelo cookie dela (fica em %LOCALAPPDATA%\WowPilot\navegador), com o servidor mandando estado, mapa e rota como sempre — e o
// pulso entregue direto pelo app (PostWebMessageAsJson, ~5 vezes por segundo, sem passar pela internet).
// Os DLLs do SDK vão embutidos no .exe (build.cmd); o loader nativo é extraído na primeira vez.
// C# 5 (csc.exe do .NET Framework 4).
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace WowPilot {

public static class WebLibs {
    public const string SdkVersion = "1.0.4191.47";   // client/webview2/README.txt
    static readonly Dictionary<string, Assembly> loaded = new Dictionary<string, Assembly>();
    static bool loaderSet;

    // a pasta do loader só pode ser dada uma vez por processo (depois do primeiro uso o WebView2 recusa): a segunda
    // janela (mapa por cima, ou o site reaberto) caía no navegador por isso
    public static void UseLoader(string configDir) {
        if (loaderSet) return;
        CoreWebView2Environment.SetLoaderDllFolderPath(LoaderDir(configDir));
        loaderSet = true;
    }

    // chamado no início do Main, antes de qualquer classe que use o WebView2 ser compilada pelo JIT
    public static void Register() {
        AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
            string name = new AssemblyName(e.Name).Name;
            if (!name.StartsWith("Microsoft.Web.WebView2.", StringComparison.Ordinal)) return null;
            lock (loaded) {
                Assembly a;
                if (loaded.TryGetValue(name, out a)) return a;
                byte[] bytes = Resource("webview2." + name + ".dll");
                if (bytes == null) return null;
                return loaded[name] = Assembly.Load(bytes);
            }
        };
    }

    static byte[] Resource(string name) {
        using (Stream st = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if (st == null) return null;
            var ms = new MemoryStream();
            st.CopyTo(ms);
            return ms.ToArray();
        }
    }

    // pasta com o WebView2Loader.dll da arquitetura deste processo (extraído do .exe se ainda não estiver lá)
    public static string LoaderDir(string configDir) {
        string arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "";
        arch = arch.Equals("ARM64", StringComparison.OrdinalIgnoreCase) ? "arm64" : Environment.Is64BitProcess ? "x64" : "x86";
        string dir = Path.Combine(configDir, "webview2", SdkVersion, arch), dll = Path.Combine(dir, "WebView2Loader.dll");
        if (!File.Exists(dll)) {
            byte[] bytes = Resource("webview2." + arch + ".WebView2Loader.dll");
            if (bytes == null) throw new FileNotFoundException("WebView2Loader.dll (" + arch + ") não veio no programa");
            Directory.CreateDirectory(dir);
            string tmp = dll + ".tmp";
            File.WriteAllBytes(tmp, bytes);
            File.Move(tmp, dll);
        }
        return dir;
    }
}

public class SiteForm : Form {
    readonly WebView2 web = new WebView2();
    readonly string server, configDir, token;
    bool ready;
    DateTime autoLoginAt = DateTime.MinValue;
    // não deu para abrir (sem o WebView2 Runtime, por exemplo): quem abriu cai para o navegador
    public event Action<string> Failed;

    readonly string startPath;
    readonly bool overlay;

    // overlay: "Mapa por cima do jogo" — janela pequena, sempre na frente (mesmo com o jogo em foco, em janela ou tela
    // cheia em janela), só com o mapa seguindo você (/mapa/me/?sobrepor=1); posição e tamanho lembrados
    public SiteForm(Config cfg, string configDir, bool overlay = false) {
        this.overlay = overlay;
        startPath = overlay ? "/mapa/me/?sobrepor=1" : "/";
        server = cfg.Server.TrimEnd('/');
        token = cfg.Token ?? "";
        this.configDir = configDir;
        Text = "WowPilot";
        Icon = Theme.App;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96f, 96f);
        ClientSize = new Size(1360, 860);
        MinimumSize = new Size(640, 480);
        StartPosition = FormStartPosition.CenterScreen;
        if (overlay) {
            Text = "WowPilot · mapa";
            FormBorderStyle = FormBorderStyle.SizableToolWindow;   // barra fininha, fora da barra de tarefas e do Alt+Tab
            ShowInTaskbar = false;
            TopMost = true;
            MinimumSize = new Size(160, 120);
            StartPosition = FormStartPosition.Manual;
            Bounds = SavedBounds();
            FormClosing += (s, e) => SaveBounds();
        }
        BackColor = Color.FromArgb(17, 19, 24);
        web.Dock = DockStyle.Fill;
        web.DefaultBackgroundColor = BackColor;
        web.CreationProperties = new CoreWebView2CreationProperties { UserDataFolder = Path.Combine(configDir, "navegador") };
        Controls.Add(web);
        Load += async (s, e) => await Init();
    }

    async Task Init() {
        try {
            WebLibs.UseLoader(configDir);
            await web.EnsureCoreWebView2Async(null);
        } catch (WebView2RuntimeNotFoundException) {
            Fail("falta o Microsoft Edge WebView2 Runtime neste Windows");
            return;
        } catch (Exception e) {
            Fail(e.GetType().Name + ": " + e.Message);
            return;
        }
        CoreWebView2 core = web.CoreWebView2;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = true;
        // links para fora (Wowhead, downloads de outros sites, target=_blank): no navegador padrão
        core.NewWindowRequested += (s, e) => {
            e.Handled = true;
            if (Ours(e.Uri)) web.CoreWebView2.Navigate(e.Uri);
            else Integration.Open(e.Uri);
        };
        core.NavigationStarting += (s, e) => {
            // a sessão caiu (expirou, saiu em outro lugar): entra de novo com o token, no máximo uma vez por minuto
            if (e.Uri.StartsWith(server + "/entrar/", StringComparison.OrdinalIgnoreCase) && token.Length > 0
                    && (DateTime.Now - autoLoginAt).TotalSeconds > 60) {
                e.Cancel = true;
                AppLogin(NextOf(e.Uri));
                return;
            }
            if (Ours(e.Uri) || !e.IsUserInitiated) return;
            e.Cancel = true;
            if (e.Uri.StartsWith("http", StringComparison.OrdinalIgnoreCase)) Integration.Open(e.Uri);
        };
        core.DocumentTitleChanged += (s, e) => {
            if (overlay) return;
            string t = web.CoreWebView2.DocumentTitle;
            Text = string.IsNullOrEmpty(t) ? "WowPilot" : t;
        };
        ready = true;
        if (token.Length > 0) AppLogin(startPath);
        else core.Navigate(server + startPath);
    }

    // entra com o token do programa: ele vai no cabeçalho (não fica na URL nem no histórico) e o site cria a sessão
    void AppLogin(string next) {
        autoLoginAt = DateTime.Now;
        CoreWebView2 core = web.CoreWebView2;
        CoreWebView2WebResourceRequest req = core.Environment.CreateWebResourceRequest(
            server + "/app/entrar?next=" + Uri.EscapeDataString(next), "GET", null,
            "Authorization: Token " + token + "\r\nX-WowPilot-Client: exe/" + Http.Version);
        core.NavigateWithWebResourceRequest(req);
    }

    static string NextOf(string uri) {
        int i = uri.IndexOf("next=", StringComparison.Ordinal);
        if (i < 0) return "/";
        string v = uri.Substring(i + 5);
        int amp = v.IndexOf('&');
        if (amp >= 0) v = v.Substring(0, amp);
        v = Uri.UnescapeDataString(v);
        return v.StartsWith("/") && !v.StartsWith("//") ? v : "/";
    }

    bool Ours(string uri) {
        return uri != null && (uri.Equals(server, StringComparison.OrdinalIgnoreCase)
            || uri.StartsWith(server + "/", StringComparison.OrdinalIgnoreCase) || uri.StartsWith(server + "?", StringComparison.OrdinalIgnoreCase));
    }

    void Fail(string why) {
        var h = Failed;
        if (h != null) h(why);
        BeginInvoke((Action)Close);
    }

    // pulso decodificado da faixa do jogo: só para a página do próprio site (nunca para outro endereço)
    public void Pulse(string json) {
        if (!ready || IsDisposed) return;
        CoreWebView2 core = web.CoreWebView2;
        if (core == null || !Ours(core.Source)) return;
        try { core.PostWebMessageAsJson("{\"kind\":\"pulse\",\"d\":" + json + "}"); } catch { }
    }

    string BoundsFile { get { return Path.Combine(configDir, "mapa-por-cima.txt"); } }

    // padrão: canto inferior direito da tela principal (longe do canto superior esquerdo do jogo, onde fica a faixa
    // do pulso: se a janela cobrir a faixa, a posição para)
    Rectangle SavedBounds() {
        try {
            string[] v = File.ReadAllText(BoundsFile).Trim().Split(',');
            var r = new Rectangle(int.Parse(v[0]), int.Parse(v[1]), int.Parse(v[2]), int.Parse(v[3]));
            foreach (Screen sc in Screen.AllScreens) if (sc.WorkingArea.IntersectsWith(r)) return r;
        } catch { }
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        int w = Math.Min(480, wa.Width / 3), h = Math.Min(400, wa.Height / 2);
        return new Rectangle(wa.Right - w - 16, wa.Bottom - h - 16, w, h);
    }

    void SaveBounds() {
        if (WindowState != FormWindowState.Normal) return;
        try { File.WriteAllText(BoundsFile, Left + "," + Top + "," + Width + "," + Height); } catch { }
    }

    protected override void Dispose(bool disposing) {
        if (disposing) web.Dispose();
        base.Dispose(disposing);
    }
}
}
