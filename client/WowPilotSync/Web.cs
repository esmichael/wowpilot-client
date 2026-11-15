// Site dentro do app (WebView2, o motor do Edge que já vem no Windows 10/11): a mesma página do navegador, logada pelo
// cookie dela (fica em %LOCALAPPDATA%\WowPilot\navegador), com o servidor mandando estado, mapa e rota como sempre — e o
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
    readonly string server, configDir;
    bool ready;
    // não deu para abrir (sem o WebView2 Runtime, por exemplo): quem abriu cai para o navegador
    public event Action<string> Failed;

    public SiteForm(string server, string configDir) {
        this.server = server.TrimEnd('/');
        this.configDir = configDir;
        Text = "WowPilot";
        Icon = Theme.App;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96f, 96f);
        ClientSize = new Size(1360, 860);
        MinimumSize = new Size(640, 480);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(17, 19, 24);
        web.Dock = DockStyle.Fill;
        web.DefaultBackgroundColor = BackColor;
        web.CreationProperties = new CoreWebView2CreationProperties { UserDataFolder = Path.Combine(configDir, "navegador") };
        Controls.Add(web);
        Load += async (s, e) => await Init();
    }

    async Task Init() {
        try {
            CoreWebView2Environment.SetLoaderDllFolderPath(WebLibs.LoaderDir(configDir));
            await web.EnsureCoreWebView2Async(null);
        } catch (WebView2RuntimeNotFoundException) {
            Fail("falta o Microsoft Edge WebView2 Runtime neste Windows");
            return;
        } catch (Exception e) {
            Fail(e.Message);
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
            if (Ours(e.Uri) || !e.IsUserInitiated) return;
            e.Cancel = true;
            if (e.Uri.StartsWith("http", StringComparison.OrdinalIgnoreCase)) Integration.Open(e.Uri);
        };
        core.DocumentTitleChanged += (s, e) => {
            string t = web.CoreWebView2.DocumentTitle;
            Text = string.IsNullOrEmpty(t) ? "WowPilot" : t;
        };
        ready = true;
        core.Navigate(server + "/");
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

    protected override void Dispose(bool disposing) {
        if (disposing) web.Dispose();
        base.Dispose(disposing);
    }
}
}
