// Configuração e laço de sincronização (o mesmo comportamento do WowPilotSync.ps1, sem a interface).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace WowPilot {

public class Config {
    public string Server = "", Token = "", WowPath = "";
    public bool KeepScreenshots, NoChatLog;
    public bool SendChat;
    public bool NoStartMenu, DesktopShortcut;
    public bool NoPulse;          // pulso (posição a cada segundo lida da tela do jogo): ligado por padrão
    public bool NoAddonInstall;   // addon embutido: instala/atualiza sozinho no Retail e no Forever (padrão)   // atalhos: Menu Iniciar ligado, Área de Trabalho desligado (padrão)   // mensagens do chat: desligado por padrão (o addon coleta, o cliente tira antes de enviar)

    public static string DefaultDir {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WowPilot"); }
    }

    public const string DefaultServer = "https://wowpilot.mican.com.br";   // o WowPilot oficial; dá para trocar

    public bool Complete { get { return Server.Length > 0 && Token.Length > 0; } }

    // mesmo config.json do WowPilotSync.ps1 (chaves Server/Token/WowPath)
    public static Config Load(string dir) {
        Config c = new Config { Server = DefaultServer };
        string file = Path.Combine(dir, "config.json");
        if (!File.Exists(file)) return c;
        try {
            var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(file));
            object v;
            if (d.TryGetValue("Server", out v) && v != null && v.ToString().Trim().Length > 0) c.Server = v.ToString();
            if (d.TryGetValue("Token", out v) && v != null) c.Token = v.ToString();
            if (d.TryGetValue("WowPath", out v) && v != null) c.WowPath = v.ToString();
            if (d.TryGetValue("KeepScreenshots", out v) && v is bool) c.KeepScreenshots = (bool)v;
            if (d.TryGetValue("NoChatLog", out v) && v is bool) c.NoChatLog = (bool)v;
            if (d.TryGetValue("SendChat", out v) && v is bool) c.SendChat = (bool)v;
            if (d.TryGetValue("NoStartMenu", out v) && v is bool) c.NoStartMenu = (bool)v;
            if (d.TryGetValue("DesktopShortcut", out v) && v is bool) c.DesktopShortcut = (bool)v;
            if (d.TryGetValue("NoAddonInstall", out v) && v is bool) c.NoAddonInstall = (bool)v;
            if (d.TryGetValue("NoPulse", out v) && v is bool) c.NoPulse = (bool)v;
        } catch { }
        return c;
    }

    public void Save(string dir) {
        Directory.CreateDirectory(dir);
        var d = new Dictionary<string, object> {
            { "Server", Server }, { "Token", Token }, { "WowPath", WowPath },
            { "KeepScreenshots", KeepScreenshots }, { "NoChatLog", NoChatLog }, { "SendChat", SendChat },
            { "NoStartMenu", NoStartMenu }, { "DesktopShortcut", DesktopShortcut }, { "NoAddonInstall", NoAddonInstall }, { "NoPulse", NoPulse } };
        File.WriteAllText(Path.Combine(dir, "config.json"), new JavaScriptSerializer().Serialize(d), new UTF8Encoding(false));
    }

    public void Normalize() {
        Server = NormalizeServer(Server);
        Token = (Token ?? "").Trim();
        WowPath = NormalizeWowPath(WowPath);
    }

    public static string NormalizeServer(string s) {
        s = (s ?? "").Trim().TrimEnd('/');
        if (s.Length == 0) return s;
        if (!Regex.IsMatch(s, "^https?://", RegexOptions.IgnoreCase)) s = "https://" + s;
        return s;
    }

    // o .NET Framework tenta IPv6 (::1) primeiro em 'localhost' e trava quando o site só escuta IPv4
    public static string ApiBase(string server) {
        return Regex.Replace(server, "^(https?://)localhost(?=[:/]|$)", "${1}127.0.0.1", RegexOptions.IgnoreCase);
    }

    // vazio = automático (WowInstall.Find); escolhida pelo usuário = a pasta "World of Warcraft"
    public static string NormalizeWowPath(string p) {
        return WowInstall.RootOf(p);
    }
}

public class HttpResult {
    public int Status;      // 0 = sem resposta (rede)
    public string Body = "", Error = "";
    public bool Ok { get { return Status >= 200 && Status < 300; } }
    public bool AuthFailed { get { return Status == 401 || Status == 403; } }
}

public static class Http {
    public const string Version = "1.7.1";

    static Http() {
        try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
        ServicePointManager.Expect100Continue = false;
    }

    public static HttpResult Send(Config cfg, string method, string path, byte[] body, string contentType, int timeoutMs) {
        HttpResult r = new HttpResult();
        try {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Config.ApiBase(cfg.Server) + path);
            req.Method = method;
            req.Timeout = req.ReadWriteTimeout = timeoutMs;
            req.Headers["Authorization"] = "Token " + cfg.Token;
            req.Headers["X-WowPilot-Client"] = "exe/" + Version;
            req.UserAgent = "WowPilotSync/" + Version;
            if (body != null) {
                byte[] gz = Decoder.Gzip(body);
                req.ContentType = contentType;
                req.Headers["Content-Encoding"] = "gzip";
                req.ContentLength = gz.Length;
                using (Stream s = req.GetRequestStream()) s.Write(gz, 0, gz.Length);
            }
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) Read(resp, r);
        } catch (WebException e) {
            HttpWebResponse resp = e.Response as HttpWebResponse;
            if (resp != null) using (resp) Read(resp, r);
            r.Error = e.Message;
        } catch (Exception e) {
            r.Error = e.Message;
        }
        return r;
    }

    static void Read(HttpWebResponse resp, HttpResult r) {
        r.Status = (int)resp.StatusCode;
        using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) r.Body = sr.ReadToEnd();
    }

    // usuário dono do token, ou null (ver r.Status / r.Error)
    public static string WhoAmI(Config cfg, out HttpResult r) {
        r = Send(cfg, "GET", "/api/whoami", null, null, 15000);
        if (!r.Ok) return null;
        try {
            var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(r.Body);
            object u;
            return d.TryGetValue("user", out u) && u != null ? u.ToString() : "?";
        } catch { return "?"; }
    }
}

public enum SyncState { Starting, Ok, Warning, Error, Stopped }
public enum LogLevel { Info, Ok, Warn, Error }

public class Engine {
    public readonly Config Cfg;
    public readonly string ConfigDir, PendingDir, LogFile;
    // variações do jogo achadas ao iniciar (o programa reinicia isto ao abrir e ao salvar as configurações)
    public List<Flavor> Flavors = new List<Flavor>();
    public string[] ShotDirs = new string[0];   // Screenshots de cada variação (Retail primeiro)
    public string ShotDir = "", ChatLog = "";   // a primeira; chat log do Retail (o único que esconde chat em combate)
    readonly string fixedShotDir;
    public int MaxAgeHours = 24;

    public event Action<DateTime, string, LogLevel> Logged;
    public event Action Changed;

    public SyncState State = SyncState.Starting;
    public string StateText = "iniciando…", User;
    public int Sent;
    public DateTime LastSent = DateTime.MinValue;
    public int Pending;

    readonly Assembler assembler = new Assembler();
    readonly Dictionary<string, string> seen = new Dictionary<string, string>();
    DateTime lastChat = DateTime.MinValue, lastPendingTry = DateTime.MinValue;
    Thread thread, pulseThread;
    volatile bool stop;
    public int Pulses;
    public DateTime LastPulse = DateTime.MinValue;
    readonly ManualResetEvent wake = new ManualResetEvent(false);

    public Engine(Config cfg, string configDir, string shotDir) {
        Cfg = cfg;
        ConfigDir = configDir;
        PendingDir = Path.Combine(configDir, "pendentes");
        LogFile = Path.Combine(configDir, "WowPilotSync.log");
        fixedShotDir = shotDir;
        Scan();
        Directory.CreateDirectory(PendingDir);
        try {
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 1 << 20) { File.Copy(LogFile, LogFile + ".old", true); File.Delete(LogFile); }
        } catch { }
    }

    // procura as variações do jogo
    void Scan() {
        List<Flavor> found = WowInstall.Find(Cfg.WowPath);
        Flavors = found;
        if (!string.IsNullOrEmpty(fixedShotDir)) ShotDirs = new[] { fixedShotDir };
        else ShotDirs = found.Select(f => f.Screenshots).ToArray();
        ShotDir = ShotDirs.Length > 0 ? ShotDirs[0] : "";
        Flavor chat = found.FirstOrDefault(f => string.Equals(f.Product, "wow", StringComparison.OrdinalIgnoreCase));
        ChatLog = chat != null ? chat.ChatLog : "";
    }

    void LogFlavors() {
        if (Flavors.Count == 0) {
            Log("não achei o World of Warcraft neste PC — escolha a pasta em Configurações", LogLevel.Warn);
            return;
        }
        foreach (Flavor f in Flavors) Log("jogo: " + f.Name + " — " + f.Dir, LogLevel.Info);
    }

    void Log(string msg, LogLevel level) {
        DateTime now = DateTime.Now;
        try { File.AppendAllText(LogFile, now.ToString("yyyy-MM-dd [HH:mm:ss] ") + msg + "\r\n", Encoding.UTF8); } catch { }
        var h = Logged;
        if (h != null) h(now, msg, level);
    }

    void SetState(SyncState s, string text) {
        State = s; StateText = text;
        Fire();
    }

    void Fire() { var h = Changed; if (h != null) h(); }

    public void Start() {
        stop = false;
        thread = new Thread(Run) { IsBackground = true, Name = "WowPilotSync" };
        thread.Start();
        if (!Cfg.NoPulse) {
            pulseThread = new Thread(PulseLoop) { IsBackground = true, Name = "WowPilotPulse" };
            pulseThread.Start();
        }
    }

    public void Stop() {
        stop = true;
        wake.Set();
        if (thread != null && thread != Thread.CurrentThread) thread.Join(5000);
        SetState(SyncState.Stopped, "parado");
    }

    // processa o que houver na pasta e volta (teste / --once); true se tudo certo
    public bool RunOnce() {
        if (!Connect()) return false;
        Tick(true);
        return true;
    }

    bool Connect() {
        Log("WowPilot Sync " + Http.Version + " — site: " + Cfg.Server, LogLevel.Info);
        LogFlavors();
        Log(Cfg.SendChat ? "chat: enviado" + (Cfg.NoChatLog ? "" : " (com o chat log)") : "chat: não enviado", LogLevel.Info);
        if (File.Exists(ChatLog)) lastChat = File.GetLastWriteTimeUtc(ChatLog);  // só manda quando mudar
        HttpResult r;
        User = Http.WhoAmI(Cfg, out r);
        if (User != null) {
            Log("conectado como " + User, LogLevel.Ok);
            SetState(SyncState.Ok, "conectado como " + User);
        } else if (r.AuthFailed) {
            Log("token inválido — gere outro na página Configurar do site", LogLevel.Error);
            SetState(SyncState.Error, "token inválido");
            return false;
        } else {
            Log("não consegui falar com o site agora (" + Describe(r) + "); sigo tentando", LogLevel.Warn);
            SetState(SyncState.Warning, "site fora do ar — guardando os envios");
        }
        return true;
    }

    void Run() {
        if (!Cfg.NoAddonInstall) foreach (string line in AddonInstaller.Sync(Flavors)) Log(line, LogLevel.Ok);
        if (!Connect()) return;
        Log("vigiando…", LogLevel.Info);
        while (!stop) {
            try { Tick(false); } catch (Exception e) { Log("erro: " + e.Message, LogLevel.Error); }
            wake.WaitOne(1000);
            wake.Reset();
        }
    }

    // pulso: a cada segundo lê a faixa do addon na janela do jogo e manda ao site quando ela muda (posição, vida…).
    // Sem janela à vista (minimizada, encoberta, tela cheia exclusiva) não manda nada; os prints seguem como antes.
    void PulseLoop() {
        var lastSeq = new Dictionary<uint, int>();
        var sentAt = new Dictionary<uint, DateTime>();
        var flushed = new HashSet<uint>();   // parado: o último pulso vai de novo uma vez (o site monta a rota com ele)
        bool reading = false, failing = false;
        DateTime lastSeen = DateTime.MinValue;
        while (!stop) {
            DateTime t0 = DateTime.Now;
            try {
                List<PulseData> found = Cfg.Complete ? Pulse.ReadScreen() : new List<PulseData>();
                if (found.Count > 0) {
                    lastSeen = DateTime.Now;
                    if (!reading) { reading = true; Log("pulso: lendo a faixa do jogo (posição a cada segundo, sem print)", LogLevel.Ok); }
                } else if (reading && (DateTime.Now - lastSeen).TotalSeconds > 120) {
                    reading = false;
                    Log("pulso: faixa fora de vista (jogo minimizado, encoberto ou fechado)", LogLevel.Info);
                }
                foreach (PulseData d in found) {
                    int prev;
                    DateTime at;
                    if (lastSeq.TryGetValue(d.Char, out prev) && prev == d.Seq) {
                        if (flushed.Contains(d.Char) || !sentAt.TryGetValue(d.Char, out at) || (DateTime.Now - at).TotalSeconds < 6) continue;
                        flushed.Add(d.Char);
                    } else flushed.Remove(d.Char);
                    sentAt[d.Char] = DateTime.Now;
                    HttpResult r = Http.Send(Cfg, "POST", "/api/pulse", Encoding.UTF8.GetBytes(d.Json()), "application/json; charset=utf-8", 5000);
                    if (r.Ok || (r.Status >= 400 && r.Status < 500 && !r.AuthFailed)) lastSeq[d.Char] = d.Seq;
                    if (r.Ok) {
                        Pulses++;
                        LastPulse = DateTime.Now;
                        if (failing) { failing = false; Log("pulso: voltou a enviar", LogLevel.Ok); }
                    } else if (!failing) {
                        failing = true;
                        Log("pulso: o site não aceitou (" + Describe(r) + ")", LogLevel.Warn);
                    }
                }
            } catch (Exception e) {
                if (!failing) { failing = true; Log("pulso: " + e.Message, LogLevel.Warn); }
            }
            int wait = 1000 - (int)(DateTime.Now - t0).TotalMilliseconds;
            if (wait > 0) Thread.Sleep(wait);
        }
    }

    static string Describe(HttpResult r) {
        return r.Status > 0 ? "HTTP " + r.Status : r.Error;
    }

    void Tick(bool once) {
        foreach (string dir in ShotDirs) {
            if (!Directory.Exists(dir)) continue;
            FileInfo[] files;
            try { files = new DirectoryInfo(dir).GetFiles("*.png").OrderBy(f => f.Name, StringComparer.Ordinal).ToArray(); }
            catch { files = new FileInfo[0]; }
            foreach (FileInfo f in files) {
                if (stop) return;
                ProcessShot(f, once);
            }
        }
        if (Cfg.SendChat && !Cfg.NoChatLog) SendChatLog();
        if ((DateTime.Now - lastPendingTry).TotalSeconds >= 30) {
            lastPendingTry = DateTime.Now;
            SendPending();
        }
    }

    void ProcessShot(FileInfo f, bool once) {
        string sig = f.LastWriteTimeUtc.Ticks + "|" + f.Length, prev;
        seen.TryGetValue(f.FullName, out prev);
        if (prev == "done") return;
        if (f.LastWriteTime < DateTime.Now.AddHours(-MaxAgeHours)) { seen[f.FullName] = "done"; return; }
        if (prev != sig && !once) { seen[f.FullName] = sig; return; }   // espera o jogo terminar de gravar
        seen[f.FullName] = "done";
        Frame frame = null;
        try { frame = Decoder.DecodeFile(f.FullName); } catch (Exception e) { Log("erro lendo " + f.Name + ": " + e.Message, LogLevel.Warn); }
        if (frame == null) return;   // print normal
        byte[] data = null;
        try { data = assembler.Add(frame); } catch (Exception e) { Log("mensagem inválida em " + f.Name + ": " + e.Message, LogLevel.Warn); }
        if (!Cfg.KeepScreenshots) {
            try { f.Delete(); } catch { Log("não apaguei " + f.Name, LogLevel.Warn); }
        }
        if (data == null) {
            if (frame.Total > 1) Log(string.Format("página {0}/{1} ({2})", frame.Page + 1, frame.Total, f.Name), LogLevel.Info);
            return;
        }
        if (frame.Kind != 3) return;
        if (!Cfg.SendChat) data = Decoder.DropKey(data, "chat");
        if (SendSnapshot(data)) {
            Sent++;
            LastSent = DateTime.Now;
            Log(string.Format("enviado #{0}: {1:N1} KB ({2} cores, {3} print(s))", Sent, data.Length / 1024.0,
                1 << frame.Bits, Math.Max(1, frame.Total)), LogLevel.Ok);
            if (State != SyncState.Ok && User != null) SetState(SyncState.Ok, "conectado como " + User);
            else Fire();
        } else {
            File.WriteAllBytes(Path.Combine(PendingDir, DateTime.Now.ToString("yyyyMMdd_HHmmss_fff") + ".json"), data);
            CountPending();
        }
    }

    bool SendSnapshot(byte[] data) {
        HttpResult r = Http.Send(Cfg, "POST", "/api/ingest", data, "application/json; charset=utf-8", 30000);
        if (r.Ok) return true;
        if (r.AuthFailed) {
            Log("token recusado pelo site (" + r.Status + ") — gere outro na página Configurar", LogLevel.Error);
            SetState(SyncState.Error, "token recusado pelo site");
        } else if (r.Status >= 400 && r.Status < 500) {
            Log("o site recusou os dados (" + r.Status + "): " + r.Error, LogLevel.Error);
            return true;  // não adianta reenviar
        } else {
            Log("site indisponível (" + Describe(r) + ") — guardado para reenviar", LogLevel.Warn);
            SetState(SyncState.Warning, "site fora do ar — guardando os envios");
        }
        return false;
    }

    void CountPending() {
        try { Pending = Directory.GetFiles(PendingDir, "*.json").Length; } catch { }
        Fire();
    }

    void SendPending() {
        foreach (string p in Directory.GetFiles(PendingDir, "*.json").OrderBy(x => x, StringComparer.Ordinal)) {
            if (stop) break;
            if (!SendSnapshot(File.ReadAllBytes(p))) break;
            File.Delete(p);
            Log("pendente " + Path.GetFileName(p) + " enviado", LogLevel.Ok);
            if (User != null && State != SyncState.Ok) SetState(SyncState.Ok, "conectado como " + User);
        }
        CountPending();
    }

    // chat log do jogo (gravado pelo WoW no logout): manda o fim do arquivo quando muda
    void SendChatLog() {
        if (!File.Exists(ChatLog)) return;
        DateTime mt = File.GetLastWriteTimeUtc(ChatLog);
        if (mt == lastChat || (DateTime.UtcNow - mt).TotalSeconds <= 3) return;
        lastChat = mt;
        try {
            byte[] buf;
            using (FileStream fs = new FileStream(ChatLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                int n = (int)Math.Min(fs.Length, 1 << 20);
                fs.Seek(-n, SeekOrigin.End);
                buf = new byte[n];
                int got = 0;
                while (got < n) { int k = fs.Read(buf, got, n - got); if (k <= 0) break; got += k; }
            }
            HttpResult r = Http.Send(Cfg, "POST", "/api/chatlog", buf, "text/plain; charset=utf-8", 30000);
            if (r.Ok) Log("chat log enviado (" + Math.Round(buf.Length / 1024.0) + " KB)", LogLevel.Ok);
            else Log("chat log: " + Describe(r), LogLevel.Warn);
        } catch (Exception e) { Log("chat log: " + e.Message, LogLevel.Warn); }
    }
}
}
