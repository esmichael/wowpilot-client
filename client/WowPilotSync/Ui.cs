// Interface: ícone na bandeja, janela de status e janela de configuração.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace WowPilot {

public static class Program {
    const string MutexName = @"Local\WowPilotSync";
    const string ShowEventName = @"Local\WowPilotSync.Show";

    [STAThread]
    public static int Main(string[] args) {
        var opt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string url = null;
        for (int i = 0; i < args.Length; i++) {
            string a = args[i];
            if (a.StartsWith("wowpilot:", StringComparison.OrdinalIgnoreCase)) url = a;
            else if (a.StartsWith("--")) {
                bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("--");
                opt[a.Substring(2)] = hasValue && IsValued(a) ? args[++i] : "1";
            }
        }
        string dir = opt.ContainsKey("config-dir") ? opt["config-dir"] : Config.DefaultDir;
        Directory.CreateDirectory(dir);
        string pidText;   // aberto pela atualização: espera a versão antiga fechar
        if (opt.TryGetValue("after-update", out pidText)) {
            try { Process.GetProcessById(int.Parse(pidText)).WaitForExit(15000); } catch { }
        }
        Updater.Cleanup(Application.ExecutablePath);
        if (opt.ContainsKey("list-games")) return ListGames(opt, dir);
        if (opt.ContainsKey("update")) return UpdateCli(opt, dir);
        if (opt.ContainsKey("install-addon")) {   // testes/suporte: instala/atualiza o addon embutido e sai
            string w;
            if (!opt.TryGetValue("wow", out w)) w = Config.Load(dir).WowPath;
            foreach (string line in AddonInstaller.Sync(WowInstall.Find(w))) Console.WriteLine(line);
            return 0;
        }
        if (opt.ContainsKey("sync-shortcuts")) {   // testes: aplica os atalhos da configuração e sai
            string links;
            if (opt.TryGetValue("links-dir", out links)) Integration.LinksDir = links;
            Integration.SyncShortcuts(Config.Load(dir));
            return 0;
        }
        if (opt.ContainsKey("once")) return RunOnce(opt, dir);

        bool first;
        using (var mutex = new Mutex(true, MutexName, out first)) {
            if (!first) {
                // já está aberto: entrega o link (se houver) e pede para a outra instância aparecer
                if (url != null) File.WriteAllText(Path.Combine(dir, "abrir.txt"), url);
                try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch { }
                return 0;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Integration.RegisterProtocol();
            using (var show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName)) {
                var ctx = new TrayApp(dir, show, url, opt.ContainsKey("minimized"));
                if (!ctx.Ready) return 1;
                Application.Run(ctx);
            }
        }
        return 0;
    }

    static bool IsValued(string a) {
        switch (a.Substring(2).ToLowerInvariant()) {
            case "server": case "token": case "wow": case "screenshots": case "config-dir": case "links-dir": case "after-update": case "api": return true;
        }
        return false;
    }

    // linha de comando (testes/suporte): atualiza sem perguntar e sem reabrir; --api troca o endereço do Release
    static int UpdateCli(Dictionary<string, string> opt, string dir) {
        string v, err;
        if (opt.TryGetValue("api", out v)) Updater.Api = v;
        ReleaseInfo r = Updater.Latest(out err);
        if (r == null) { Console.WriteLine("erro: " + err); return 2; }
        if (!Updater.IsNewer(r)) { Console.WriteLine("já está na versão mais recente (" + Http.Version + ")"); return 0; }
        try {
            byte[] zip = Updater.Download(r.ZipUrl, r.ZipSha256), exe = Updater.Download(r.ExeUrl, r.ExeSha256);
            if (!opt.TryGetValue("wow", out v)) v = Config.Load(dir).WowPath;
            List<string> done = Updater.UpdateAddon(zip, WowInstall.Find(v));
            Updater.ReplaceExe(Application.ExecutablePath, exe);
            Console.WriteLine("atualizado para " + r.Tag + "; addon: " + (done.Count > 0 ? string.Join(", ", done.ToArray()) : "nenhum"));
            return 0;
        } catch (Exception e) {
            Console.WriteLine("erro: " + e.Message);
            return 3;
        }
    }

    // linha de comando (suporte/testes): variações do jogo encontradas, uma por linha (nome, produto, pasta)
    static int ListGames(Dictionary<string, string> opt, string dir) {
        string wow;
        if (!opt.TryGetValue("wow", out wow)) wow = Config.Load(dir).WowPath;
        List<Flavor> found = WowInstall.Find(wow);
        foreach (Flavor f in found) Console.WriteLine(f.Name + "\t" + f.Product + "\t" + f.Dir);
        if (found.Count == 0) Console.WriteLine("nenhuma instalação do World of Warcraft encontrada");
        return found.Count > 0 ? 0 : 1;
    }

    // linha de comando (testes): processa a pasta uma vez e sai; saída no console de quem chamou
    static int RunOnce(Dictionary<string, string> opt, string dir) {
        Config cfg = Config.Load(dir);
        string v;
        if (opt.TryGetValue("server", out v)) cfg.Server = v;
        if (opt.TryGetValue("token", out v)) cfg.Token = v;
        if (opt.TryGetValue("wow", out v)) cfg.WowPath = v;
        if (opt.ContainsKey("no-chatlog")) cfg.NoChatLog = true;
        if (opt.ContainsKey("chat")) cfg.SendChat = true;
        if (opt.ContainsKey("keep")) cfg.KeepScreenshots = true;
        cfg.Normalize();
        if (!cfg.Complete) { Console.Error.WriteLine("uso: WowPilotSync.exe --once --server URL --token TOKEN"); return 1; }
        cfg.Save(dir);
        opt.TryGetValue("screenshots", out v);
        var engine = new Engine(cfg, dir, v);
        engine.Logged += (t, msg, level) => Console.WriteLine("[" + t.ToString("HH:mm:ss") + "] " + msg);
        return engine.RunOnce() ? 0 : 2;
    }
}

// Registro do Windows (só HKCU, sem admin): link wowpilot:// e iniciar com o Windows.
public static class Integration {
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static string Exe { get { return Application.ExecutablePath; } }

    public static void RegisterProtocol() {
        try {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\wowpilot")) {
                k.SetValue("", "URL:WowPilot Sync");
                k.SetValue("URL Protocol", "");
                using (RegistryKey icon = k.CreateSubKey("DefaultIcon")) icon.SetValue("", "\"" + Exe + "\",0");
                using (RegistryKey cmd = k.CreateSubKey(@"shell\open\command")) cmd.SetValue("", "\"" + Exe + "\" \"%1\"");
            }
        } catch { }
    }

    public static bool AutoStart {
        get {
            try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue("WowPilotSync") != null; }
            catch { return false; }
        }
        set {
            try {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey)) {
                    if (value) k.SetValue("WowPilotSync", "\"" + Exe + "\" --minimized");
                    else k.DeleteValue("WowPilotSync", false);
                }
            } catch { }
        }
    }

    // Atalhos "WowPilot Sync" no Menu Iniciar e na Área de Trabalho, apontando para este .exe (portátil: se ele
    // mudar de pasta, o atalho é corrigido na próxima vez que abrir). .lnk pelo WScript.Shell, que já vem no Windows.
    public static string LinksDir;   // só testes: pasta no lugar do Menu Iniciar/Área de Trabalho
    const string LinkName = "WowPilot Sync.lnk";

    public static string StartMenuLink {
        get { return LinksDir != null ? Path.Combine(LinksDir, "menu", LinkName) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), LinkName); }
    }
    public static string DesktopLink {
        get { return LinksDir != null ? Path.Combine(LinksDir, "desktop", LinkName) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), LinkName); }
    }

    public static void SyncShortcuts(Config c) {
        SetShortcut(StartMenuLink, !c.NoStartMenu);
        SetShortcut(DesktopLink, c.DesktopShortcut);
    }

    static void SetShortcut(string link, bool want) {
        try {
            if (!want) { if (File.Exists(link)) File.Delete(link); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(link));
            Type type = Type.GetTypeFromProgID("WScript.Shell");
            if (type == null) return;
            object shell = Activator.CreateInstance(type), sc = null;
            try {
                sc = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { link });
                Type st = sc.GetType();
                string target = st.InvokeMember("TargetPath", BindingFlags.GetProperty, null, sc, null) as string;
                if (File.Exists(link) && string.Equals(target, Exe, StringComparison.OrdinalIgnoreCase)) return;
                st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { Exe });
                st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { Path.GetDirectoryName(Exe) });
                st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "WowPilot Sync" });
                st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { Exe + ",0" });
                st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
            } finally {
                if (sc != null) Marshal.FinalReleaseComObject(sc);
                Marshal.FinalReleaseComObject(shell);
            }
        } catch { }
    }

    // wowpilot://configurar?server=...&token=...
    public static bool ParseLink(string url, Config into) {
        try {
            Uri u = new Uri(url);
            bool any = false;
            foreach (string part in u.Query.TrimStart('?').Split('&')) {
                int eq = part.IndexOf('=');
                if (eq <= 0) continue;
                string k = Uri.UnescapeDataString(part.Substring(0, eq));
                string v = Uri.UnescapeDataString(part.Substring(eq + 1).Replace('+', ' '));
                if (k == "server") { into.Server = v; any = true; }
                else if (k == "token") { into.Token = v; any = true; }
            }
            return any;
        } catch { return false; }
    }

    public static void Open(string target) {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }
}

public static class Theme {
    public static readonly Font Base = new Font("Segoe UI", 9f);
    public static readonly Font Title = new Font("Segoe UI Semibold", 13f);
    public static readonly Font Small = new Font("Segoe UI", 8.25f);
    public static readonly Color Muted = Color.FromArgb(96, 100, 110);
    public static readonly Color Green = Color.FromArgb(46, 160, 67);
    public static readonly Color Yellow = Color.FromArgb(214, 158, 0);
    public static readonly Color Red = Color.FromArgb(207, 34, 46);
    public static readonly Color Gray = Color.FromArgb(140, 145, 155);
    public static readonly Color Accent = Color.FromArgb(37, 99, 235);

    public static Color For(SyncState s) {
        switch (s) {
            case SyncState.Ok: return Green;
            case SyncState.Warning: return Yellow;
            case SyncState.Error: return Red;
        }
        return Gray;
    }

    public static Color For(LogLevel l) {
        switch (l) {
            case LogLevel.Ok: return Color.FromArgb(26, 127, 55);
            case LogLevel.Warn: return Color.FromArgb(154, 103, 0);
            case LogLevel.Error: return Red;
        }
        return Color.FromArgb(40, 44, 52);
    }

    static Icon app;
    public static Icon App {
        get {
            if (app == null) {
                using (Stream s = typeof(Theme).Assembly.GetManifestResourceStream("WowPilot.app.ico"))
                    app = s != null ? new Icon(s) : SystemIcons.Application;
            }
            return app;
        }
    }

    // ícone da bandeja = ícone do app + bolinha de status
    public static Icon Tray(SyncState s) {
        Size sz = SystemInformation.SmallIconSize;
        using (Icon small = new Icon(App, sz))
        using (Bitmap bmp = new Bitmap(sz.Width, sz.Height)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.DrawIcon(small, new Rectangle(Point.Empty, sz));
                int d = sz.Width / 2 + 1;
                var r = new Rectangle(sz.Width - d, sz.Height - d, d - 1, d - 1);
                using (var b = new SolidBrush(For(s))) g.FillEllipse(b, r);
                using (var p = new Pen(Color.White, Math.Max(1f, sz.Width / 16f))) g.DrawEllipse(p, r);
            }
            IntPtr h = bmp.GetHicon();
            return Icon.FromHandle(h);
        }
    }
}

public class TrayApp : ApplicationContext {
    readonly string dir;
    readonly EventWaitHandle showEvent;
    Config cfg;
    Engine engine;
    readonly NotifyIcon tray = new NotifyIcon();
    readonly MainForm main;
    readonly Dictionary<SyncState, Icon> icons = new Dictionary<SyncState, Icon>();
    readonly ToolStripMenuItem autoItem;
    SyncState lastState = SyncState.Starting;
    bool exiting, hintShown;
    Action balloonClick;   // o que fazer ao clicar na notificação que está na tela
    public bool Ready;

    public TrayApp(string dir, EventWaitHandle showEvent, string url, bool minimized) {
        this.dir = dir;
        this.showEvent = showEvent;
        cfg = Config.Load(dir);
        Integration.SyncShortcuts(cfg);
        if (url != null || !cfg.Complete) {
            Config proposal = Config.Load(dir);
            if (url != null) Integration.ParseLink(url, proposal);
            if (!AskSettings(proposal, null)) return;
            minimized = false;
        }
        cfg.Normalize();

        main = new MainForm();
        main.OpenDashboard += () => Integration.Open(cfg.Server + "/");
        main.OpenSettings += () => { Config c = Config.Load(dir); if (AskSettings(c, main)) StartEngine(); };
        main.OpenShots += () => {
            if (engine == null) return;
            string d = engine.ShotDirs.FirstOrDefault(Directory.Exists) ?? (engine.Flavors.Count > 0 ? engine.Flavors[0].Dir : null);
            if (d != null) Integration.Open(d);
        };
        main.FormClosing += (s, e) => {
            if (exiting || e.CloseReason != CloseReason.UserClosing) return;
            e.Cancel = true;
            main.Hide();
            if (!hintShown) {
                hintShown = true;
                Notify(4000, "WowPilot Sync continua rodando", "Ele fica aqui na bandeja enviando os dados. Clique no ícone para abrir.", ToolTipIcon.Info, ShowMain);
            }
        };
        IntPtr unused = main.Handle;  // cria a janela (BeginInvoke) mesmo escondida

        var menu = new ContextMenuStrip();
        var openItem = new ToolStripMenuItem("Abrir WowPilot Sync", null, (s, e) => ShowMain());
        openItem.Font = new Font(openItem.Font, FontStyle.Bold);
        menu.Items.Add(openItem);
        menu.Items.Add("Abrir dashboard", null, (s, e) => Integration.Open(cfg.Server + "/"));
        menu.Items.Add("Configurações…", null, (s, e) => { ShowMain(); main.ClickSettings(); });
        autoItem = new ToolStripMenuItem("Iniciar com o Windows", null, (s, e) => Integration.AutoStart = !Integration.AutoStart);
        menu.Items.Add(autoItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Sair", null, (s, e) => Exit());
        menu.Opening += (s, e) => autoItem.Checked = Integration.AutoStart;
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };
        tray.BalloonTipClicked += (s, e) => { Action a = balloonClick; balloonClick = null; (a ?? ShowMain)(); };
        tray.Icon = IconFor(SyncState.Starting);
        tray.Text = "WowPilot Sync";
        tray.Visible = true;

        // outra instância pediu para aparecer (atalho clicado de novo ou link wowpilot://)
        ThreadPool.RegisterWaitForSingleObject(showEvent, (st, timedOut) => main.BeginInvoke((Action)OnShowRequest), null, -1, false);

        StartEngine();
        if (!minimized) ShowMain();
        main.CheckForUpdate += () => CheckUpdate(false);
        CheckUpdate(true);   // ao abrir: só avisa se houver versão nova
        Ready = true;
    }

    Icon IconFor(SyncState s) {
        Icon i;
        if (!icons.TryGetValue(s, out i)) icons[s] = i = Theme.Tray(s);
        return i;
    }

    bool AskSettings(Config c, IWin32Window owner) {
        using (var f = new SettingsForm(c)) {
            if (owner == null) { f.StartPosition = FormStartPosition.CenterScreen; f.ShowInTaskbar = true; }
            if (f.ShowDialog(owner) != DialogResult.OK) return false;
            f.Result.Save(dir);
            cfg = f.Result;
            Integration.SyncShortcuts(cfg);
            return true;
        }
    }

    void OnShowRequest() {
        string file = Path.Combine(dir, "abrir.txt");
        string url = null;
        try { if (File.Exists(file)) { url = File.ReadAllText(file).Trim(); File.Delete(file); } } catch { }
        ShowMain();
        if (!string.IsNullOrEmpty(url)) {
            Config c = Config.Load(dir);
            Integration.ParseLink(url, c);
            if (AskSettings(c, main)) StartEngine();
        }
    }

    void StartEngine() {
        if (engine != null) engine.Stop();
        cfg.Normalize();
        engine = new Engine(cfg, dir, null);
        Engine e = engine;
        main.Bind(e, cfg);
        e.Logged += (t, msg, level) => main.BeginInvoke((Action)(() => { if (e == engine) main.AddLog(t, msg, level); }));
        e.Changed += () => main.BeginInvoke((Action)(() => { if (e == engine) Refresh(); }));
        Refresh();
        e.Start();
    }

    void Refresh() {
        main.UpdateStatus(engine);
        tray.Icon = IconFor(engine.State);
        string tip = "WowPilot Sync — " + engine.StateText;
        if (engine.Sent > 0) tip += " (" + engine.Sent + " envios)";
        tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        if (engine.State != lastState) {
            if (engine.State == SyncState.Error)
                Notify(5000, "WowPilot Sync", engine.StateText + ". Clique aqui para abrir as configurações.", ToolTipIcon.Error,
                       () => { ShowMain(); main.ClickSettings(); });
            else if (engine.State == SyncState.Warning && lastState == SyncState.Ok)
                Notify(5000, "WowPilot Sync", "O site não respondeu. Os dados ficam guardados e são reenviados sozinhos.", ToolTipIcon.Warning, ShowMain);
            lastState = engine.State;
        }
    }

    void ShowMain() {
        main.Show();
        if (main.WindowState == FormWindowState.Minimized) main.WindowState = FormWindowState.Normal;
        main.Activate();
    }

    void Notify(int ms, string title, string text, ToolTipIcon icon, Action onClick) {
        balloonClick = onClick;
        tray.ShowBalloonTip(ms, title, text, icon);
    }

    // ---------------------------------------------------------------- atualização
    void CheckUpdate(bool quiet) {
        new Thread(() => {
            string err;
            ReleaseInfo r = Updater.Latest(out err);
            try { main.BeginInvoke((Action)(() => OnUpdateInfo(r, err, quiet))); } catch { }
        }) { IsBackground = true }.Start();
    }

    void OnUpdateInfo(ReleaseInfo r, string err, bool quiet) {
        if (r == null) {
            if (!quiet) MessageBox.Show(main, "Não consegui ver se há versão nova (" + err + ").", "WowPilot Sync", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (!Updater.IsNewer(r)) {
            if (!quiet) MessageBox.Show(main, "Você já está na versão mais recente (" + Http.Version + ").", "WowPilot Sync", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        main.ShowUpdate(r.Tag);
        if (quiet) {
            main.AddLog(DateTime.Now, "versão nova disponível: " + r.Tag + " — clique em Atualizar para " + r.Tag, LogLevel.Warn);
            Notify(8000, "WowPilot Sync " + r.Tag + " disponível", "Clique aqui para ver e atualizar.", ToolTipIcon.Info, ShowMain);
            return;
        }
        if (MessageBox.Show(main, "Atualizar para a versão " + r.Tag + "?\n\nO programa baixa a versão nova, confere os arquivos, atualiza o addon " +
                "nas pastas do jogo onde ele está instalado e reabre sozinho. No jogo, dê /reload depois.",
                "WowPilot Sync", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        main.AddLog(DateTime.Now, "baixando a versão " + r.Tag + "…", LogLevel.Info);
        List<Flavor> flavors = engine != null ? engine.Flavors : WowInstall.Find(cfg.WowPath);
        new Thread(() => {
            string fail = null;
            try {
                byte[] zip = Updater.Download(r.ZipUrl, r.ZipSha256), exe = Updater.Download(r.ExeUrl, r.ExeSha256);
                Updater.UpdateAddon(zip, flavors);
                Updater.ReplaceExe(Application.ExecutablePath, exe);
            } catch (Exception e) { fail = e.Message; }
            try {
                main.BeginInvoke((Action)(() => {
                    if (fail != null) {
                        main.AddLog(DateTime.Now, "atualização falhou: " + fail, LogLevel.Error);
                        MessageBox.Show(main, "A atualização não deu certo: " + fail, "WowPilot Sync", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    Updater.Restart(Application.ExecutablePath);
                    Exit();
                }));
            } catch { }
        }) { IsBackground = true }.Start();
    }

    void Exit() {
        exiting = true;
        tray.Visible = false;
        if (engine != null) engine.Stop();
        main.Close();
        ExitThread();
    }
}

public class StatusDot : Control {
    Color color = Theme.Gray;
    public StatusDot() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true); BackColor = Color.Transparent; }
    public Color DotColor { get { return color; } set { color = value; Invalidate(); } }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int d = Math.Min(Width, Height) - 2;
        using (var b = new SolidBrush(color)) e.Graphics.FillEllipse(b, 1, (Height - d) / 2, d, d);
    }
}

public class MainForm : Form {
    public event Action OpenDashboard, OpenSettings, OpenShots, CheckForUpdate;
    readonly StatusDot dot = new StatusDot();
    readonly Label title = new Label(), site = new Label();
    readonly Label sentValue = new Label(), lastValue = new Label(), pendingValue = new Label(), shotsValue = new Label();
    readonly ListView log = new ListView();
    readonly Button settingsBtn, updateBtn;

    public MainForm() {
        Text = "WowPilot Sync";
        Icon = Theme.App;
        Font = Theme.Base;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96f, 96f);
        ClientSize = new Size(620, 440);
        MinimumSize = new Size(520, 360);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;

        var header = new Panel { Dock = DockStyle.Top, Height = 74, BackColor = Color.FromArgb(246, 247, 249), Padding = new Padding(16, 12, 16, 8) };
        dot.SetBounds(16, 16, 18, 18);
        title.SetBounds(42, 10, 540, 28);
        title.Font = Theme.Title;
        title.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
        title.Text = "Iniciando…";
        site.SetBounds(43, 42, 540, 20);
        site.ForeColor = Theme.Muted;
        site.Anchor = title.Anchor;
        header.Controls.AddRange(new Control[] { dot, title, site });
        var line = new Panel { Dock = DockStyle.Top, Height = 1, BackColor = Color.FromArgb(222, 225, 230) };

        var stats = new TableLayoutPanel { Dock = DockStyle.Top, ColumnCount = 4, RowCount = 2, Height = 58, Padding = new Padding(12, 10, 12, 4) };
        for (int i = 0; i < 4; i++) stats.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, i == 3 ? 40 : 20));
        AddStat(stats, 0, "Enviados (sessão)", sentValue);
        AddStat(stats, 1, "Último envio", lastValue);
        AddStat(stats, 2, "Pendentes", pendingValue);
        AddStat(stats, 3, "Jogos", shotsValue);
        shotsValue.AutoEllipsis = true;

        var logLabel = new Label { Text = "Atividade", Dock = DockStyle.Top, Height = 22, ForeColor = Theme.Muted, Padding = new Padding(14, 4, 0, 0) };
        log.View = View.Details;
        log.HeaderStyle = ColumnHeaderStyle.None;
        log.FullRowSelect = true;
        log.BorderStyle = BorderStyle.None;
        log.Columns.Add("Hora", 64);
        log.Columns.Add("Mensagem", 520);
        log.Dock = DockStyle.Fill;
        var logWrap = new Panel { Dock = DockStyle.Fill, Padding = new Padding(14, 2, 14, 4) };
        logWrap.Controls.Add(log);
        log.Resize += (s, e) => log.Columns[1].Width = Math.Max(100, log.ClientSize.Width - log.Columns[0].Width - 4);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 52, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(12, 10, 12, 10), BackColor = Color.FromArgb(246, 247, 249) };
        var hide = MakeButton("Esconder", (s, e) => Close());
        settingsBtn = MakeButton("Configurações…", (s, e) => { if (OpenSettings != null) OpenSettings(); });
        var dash = MakeButton("Abrir dashboard", (s, e) => { if (OpenDashboard != null) OpenDashboard(); });
        var shots = MakeButton("Pasta dos prints", (s, e) => { if (OpenShots != null) OpenShots(); });
        updateBtn = MakeButton("Atualizar", (s, e) => { if (CheckForUpdate != null) CheckForUpdate(); });
        buttons.Controls.AddRange(new Control[] { hide, settingsBtn, dash, shots, updateBtn });
        AcceptButton = dash;

        Controls.Add(logWrap);
        Controls.Add(logLabel);
        Controls.Add(stats);
        Controls.Add(line);
        Controls.Add(header);
        Controls.Add(buttons);
    }

    static void AddStat(TableLayoutPanel t, int col, string caption, Label value) {
        var c = new Label { Text = caption, ForeColor = Theme.Muted, Font = Theme.Small, AutoSize = true, Margin = new Padding(3, 0, 3, 2) };
        value.AutoSize = false;
        value.Dock = DockStyle.Fill;
        value.Font = new Font("Segoe UI Semibold", 10f);
        value.Text = "—";
        t.Controls.Add(c, col, 0);
        t.Controls.Add(value, col, 1);
    }

    static Button MakeButton(string text, EventHandler click) {
        var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(96, 30), Margin = new Padding(6, 0, 0, 0), UseVisualStyleBackColor = true };
        b.Click += click;
        return b;
    }

    public void ClickSettings() { settingsBtn.PerformClick(); }

    // há versão nova: o botão vira "Atualizar para vX.Y.Z", em destaque
    public void ShowUpdate(string tag) {
        updateBtn.Text = "Atualizar para " + tag;
        updateBtn.UseVisualStyleBackColor = false;
        updateBtn.FlatStyle = FlatStyle.Flat;
        updateBtn.FlatAppearance.BorderColor = Theme.Accent;
        updateBtn.BackColor = Theme.Accent;
        updateBtn.ForeColor = Color.White;
        updateBtn.Font = new Font(Font, FontStyle.Bold);
    }

    public void Bind(Engine e, Config cfg) {
        log.Items.Clear();
        site.Text = cfg.Server;
    }

    public void UpdateStatus(Engine e) {
        dot.DotColor = Theme.For(e.State);
        string t = e.StateText;
        title.Text = t.Length > 0 ? char.ToUpper(t[0]) + t.Substring(1) : t;
        sentValue.Text = e.Sent.ToString();
        lastValue.Text = e.LastSent == DateTime.MinValue ? "—" : e.LastSent.ToString("HH:mm:ss");
        pendingValue.Text = e.Pending.ToString();
        pendingValue.ForeColor = e.Pending > 0 ? Theme.Yellow : ForeColor;
        shotsValue.Text = e.Flavors.Count > 0 ? WowInstall.Describe(e.Flavors) : "não encontrado";
    }

    public void AddLog(DateTime t, string msg, LogLevel level) {
        var item = new ListViewItem(new[] { t.ToString("HH:mm:ss"), msg }) { ForeColor = Theme.For(level) };
        log.BeginUpdate();
        log.Items.Insert(0, item);
        while (log.Items.Count > 300) log.Items.RemoveAt(log.Items.Count - 1);
        log.EndUpdate();
    }
}

public class SettingsForm : Form {
    public Config Result;
    readonly TextBox server = new TextBox(), token = new TextBox(), wow = new TextBox();
    readonly CheckBox showToken = new CheckBox(), autoStart = new CheckBox(), addon = new CheckBox(), startMenu = new CheckBox(), desktop = new CheckBox(), chat = new CheckBox(), chatLog = new CheckBox(), keep = new CheckBox();
    readonly Label status = new Label(), found = new Label();
    readonly Button test, save;
    readonly Config start;

    public SettingsForm(Config c) {
        start = c;
        Text = "WowPilot Sync — configuração";
        Icon = Theme.App;
        Font = Theme.Base;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96f, 96f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Color.White;
        ClientSize = new Size(560, 536);

        var intro = new Label {
            Text = "Conecte este PC ao seu dashboard. O token é gerado na página Configurar do site.",
            ForeColor = Theme.Muted, AutoSize = false
        };
        intro.SetBounds(20, 16, 520, 20);

        var grid = new TableLayoutPanel { ColumnCount = 3, RowCount = 3 };
        grid.SetBounds(16, 44, 528, 120);
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        for (int i = 0; i < 3; i++) grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));

        server.Text = c.Server;
        token.Text = c.Token;
        token.UseSystemPasswordChar = true;
        token.Font = new Font("Consolas", 9.5f);
        wow.Text = c.WowPath;
        SetCue(server, "https://wowpilot.exemplo.com");
        SetCue(token, "cole aqui o token");
        SetCue(wow, "automático");

        showToken.Text = "Mostrar";
        showToken.AutoSize = true;
        showToken.CheckedChanged += (s, e) => token.UseSystemPasswordChar = !showToken.Checked;
        var browse = new Button { Text = "Procurar…", AutoSize = true, UseVisualStyleBackColor = true };
        browse.Click += (s, e) => Browse();

        AddRow(grid, 0, "Endereço do site", server, null);
        AddRow(grid, 1, "Token", token, showToken);
        AddRow(grid, 2, "Pasta do WoW", wow, browse);

        autoStart.Text = "Iniciar com o Windows (fica só o ícone perto do relógio)";
        autoStart.Checked = Integration.AutoStart || string.IsNullOrEmpty(c.Token);
        chat.Text = "Enviar as mensagens do chat (sussurros, grupo, guilda…)";
        chat.Checked = c.SendChat;
        chatLog.Text = "Incluir o chat log do jogo (Retail: recupera o que o jogo esconde em combate)";
        chatLog.Checked = !c.NoChatLog;
        chatLog.Enabled = chat.Checked;
        chat.CheckedChanged += (s, e) => chatLog.Enabled = chat.Checked;
        keep.Text = "Manter os prints do código depois de enviar";
        keep.Checked = c.KeepScreenshots;
        found.SetBounds(150, 174, 300, 20);
        found.ForeColor = Theme.Muted;
        found.AutoEllipsis = true;
        var rescan = new LinkLabel { Text = "Buscar de novo", AutoSize = true, Location = new Point(456, 174) };
        rescan.LinkClicked += (s, e) => ShowFound();
        wow.Leave += (s, e) => ShowFound();   // ao sair do campo, não a cada tecla
        ShowFound();
        int y = 200;
        startMenu.Text = "Atalho no Menu Iniciar";
        startMenu.Checked = !c.NoStartMenu;
        desktop.Text = "Atalho na Área de Trabalho";
        desktop.Checked = c.DesktopShortcut;
        addon.Text = "Instalar e atualizar o addon no jogo sozinho (Retail e Forever)";
        addon.Checked = !c.NoAddonInstall;
        foreach (CheckBox cb in new[] { autoStart, addon, startMenu, desktop, chat, chatLog, keep }) {
            cb.AutoSize = true;
            cb.Location = new Point(cb == chatLog ? 170 : 150, y);
            y += 28;
        }

        status.SetBounds(150, 400, 390, 44);
        status.ForeColor = Theme.Muted;

        var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 56, FlowDirection = FlowDirection.RightToLeft,
                                        Padding = new Padding(12, 13, 12, 10), BackColor = Color.FromArgb(246, 247, 249) };
        test = new Button { Text = "Testar conexão", AutoSize = true, MinimumSize = new Size(110, 30), UseVisualStyleBackColor = true };
        save = new Button { Text = "Salvar", MinimumSize = new Size(96, 30), AutoSize = true, UseVisualStyleBackColor = true };
        var cancel = new Button { Text = "Cancelar", MinimumSize = new Size(96, 30), AutoSize = true, DialogResult = DialogResult.Cancel, UseVisualStyleBackColor = true };
        foreach (Button b in new[] { cancel, save, test }) b.Margin = new Padding(6, 0, 0, 0);
        bar.Controls.AddRange(new Control[] { cancel, save, test });
        test.Click += (s, e) => RunTest(false);
        save.Click += (s, e) => RunTest(true);
        AcceptButton = save;
        CancelButton = cancel;

        Controls.AddRange(new Control[] { intro, grid, found, rescan, autoStart, addon, startMenu, desktop, chat, chatLog, keep, status, bar });
        Shown += (s, e) => (server.Text.Length == 0 ? server : token.Text.Length == 0 ? token : (Control)save).Focus();
    }

    static void AddRow(TableLayoutPanel g, int row, string caption, TextBox box, Control extra) {
        var l = new Label { Text = caption, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(4, 0, 4, 0) };
        box.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        box.Margin = new Padding(3, 0, 3, 0);
        g.Controls.Add(l, 0, row);
        g.Controls.Add(box, 1, row);
        if (extra != null) { extra.Anchor = AnchorStyles.Left; g.Controls.Add(extra, 2, row); }
        else g.SetColumnSpan(box, 2);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    static void SetCue(TextBox box, string cue) {
        box.HandleCreated += (s, e) => SendMessage(box.Handle, 0x1501 /* EM_SETCUEBANNER */, (IntPtr)1, cue);
    }

    // o que a pasta escolhida (ou a busca automática) encontra
    void ShowFound() {
        List<Flavor> f = WowInstall.Find(wow.Text);
        found.Text = f.Count > 0 ? "Encontrado: " + WowInstall.Describe(f) : "Nenhuma instalação do WoW encontrada";
        found.ForeColor = f.Count > 0 ? Theme.Muted : Theme.Yellow;
    }

    void Browse() {
        using (var d = new FolderBrowserDialog { Description = "Escolha a pasta World of Warcraft (a que tem _retail_, _forever_…)", ShowNewFolderButton = false }) {
            if (Directory.Exists(wow.Text)) d.SelectedPath = wow.Text;
            if (d.ShowDialog(this) == DialogResult.OK) { wow.Text = Config.NormalizeWowPath(d.SelectedPath); ShowFound(); }
        }
    }

    Config Collect() {
        var c = new Config {
            Server = server.Text, Token = token.Text, WowPath = wow.Text,
            SendChat = chat.Checked, NoChatLog = !chatLog.Checked, KeepScreenshots = keep.Checked,
            NoStartMenu = !startMenu.Checked, DesktopShortcut = desktop.Checked, NoAddonInstall = !addon.Checked
        };
        c.Normalize();
        return c;
    }

    void SetStatus(string text, Color color) { status.Text = text; status.ForeColor = color; }

    // testa o token no site; ao salvar, só fecha se o site aceitou (ou se o usuário insistir com o site fora do ar)
    void RunTest(bool saving) {
        Config c = Collect();
        if (c.Server.Length == 0) { SetStatus("Preencha o endereço do site.", Theme.Red); server.Focus(); return; }
        if (c.Token.Length == 0) { SetStatus("Cole o token gerado na página Configurar do site.", Theme.Red); token.Focus(); return; }
        test.Enabled = save.Enabled = false;
        SetStatus("Testando " + c.Server + "…", Theme.Muted);
        var worker = new Thread(() => {
            HttpResult r;
            string user = Http.WhoAmI(c, out r);
            BeginInvoke((Action)(() => Finish(c, user, r, saving)));
        }) { IsBackground = true };
        worker.Start();
    }

    void Finish(Config c, string user, HttpResult r, bool saving) {
        test.Enabled = save.Enabled = true;
        bool shotsOk = WowInstall.Find(c.WowPath).Count > 0;
        string warnShots = shotsOk ? "" : "\nNão achei o World of Warcraft — escolha a pasta.";
        if (user != null) {
            SetStatus("Conectado como " + user + "." + warnShots, shotsOk ? Theme.Green : Theme.Yellow);
            if (saving) Accept(c);
            return;
        }
        if (r.AuthFailed) { SetStatus("Token inválido ou revogado. Gere outro na página Configurar do site.", Theme.Red); return; }
        string why = r.Status > 0 ? "o site respondeu HTTP " + r.Status : r.Error;
        SetStatus("Não consegui falar com o site (" + why + ")." + warnShots, Theme.Red);
        if (saving && MessageBox.Show(this, "O site não respondeu agora. Salvar mesmo assim?\nOs dados ficam guardados e são enviados quando ele voltar.",
                "WowPilot Sync", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            Accept(c);
    }

    void Accept(Config c) {
        Integration.AutoStart = autoStart.Checked;
        Result = c;
        DialogResult = DialogResult.OK;
        Close();
    }
}
}
