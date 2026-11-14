// Atualização: baixa o Release mais recente do GitHub (WowPilotSync.exe + WowPilot.zip), confere o SHA-256 que o
// GitHub publica para cada arquivo, atualiza o addon onde ele já está instalado e troca o .exe (o Windows deixa
// renomear um .exe em uso: o atual vira .old, o novo entra no lugar e é aberto; o .old é apagado na abertura seguinte).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

namespace WowPilot {
public class ReleaseInfo {
    public string Tag, Page, ExeUrl, ExeSha256, ZipUrl, ZipSha256;
    public Version Version;
}

public static class Updater {
    public static string Api = "https://api.github.com/repos/esmichael/wowpilot-client/releases/latest";
    const int MaxBytes = 50 << 20;

    static Updater() {
        try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
    }

    public static Version Current { get { return new Version(Http.Version); } }

    // Release mais recente, ou null (error diz por quê)
    public static ReleaseInfo Latest(out string error) {
        error = null;
        try {
            string json;
            using (var r = Get(Api, "application/vnd.github+json"))
            using (var sr = new StreamReader(r.GetResponseStream())) json = sr.ReadToEnd();
            var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            var info = new ReleaseInfo { Tag = d["tag_name"] as string, Page = d.ContainsKey("html_url") ? d["html_url"] as string : null };
            info.Version = new Version((info.Tag ?? "").TrimStart('v', 'V'));
            foreach (object o in (System.Collections.ArrayList)d["assets"]) {
                var a = (Dictionary<string, object>)o;
                string name = a["name"] as string, url = a["browser_download_url"] as string;
                string digest = a.ContainsKey("digest") ? a["digest"] as string : null;
                string sha = digest != null && digest.StartsWith("sha256:") ? digest.Substring(7).ToLowerInvariant() : null;
                if (name == "WowPilotSync.exe") { info.ExeUrl = url; info.ExeSha256 = sha; }
                else if (name == "WowPilot.zip") { info.ZipUrl = url; info.ZipSha256 = sha; }
            }
            if (info.ExeUrl == null || info.ZipUrl == null) { error = "a versão " + info.Tag + " não tem os arquivos esperados"; return null; }
            if (info.ExeSha256 == null || info.ZipSha256 == null) { error = "a versão " + info.Tag + " não publicou o SHA-256 dos arquivos"; return null; }
            return info;
        } catch (WebException e) {
            var resp = e.Response as HttpWebResponse;
            error = resp != null ? "o GitHub respondeu HTTP " + (int)resp.StatusCode : e.Message;
        } catch (Exception e) {
            error = e.Message;
        }
        return null;
    }

    public static bool IsNewer(ReleaseInfo r) { return r != null && r.Version > Current; }

    // baixa e confere o SHA-256; lança exceção se não bater
    public static byte[] Download(string url, string sha256) {
        byte[] data;
        using (var r = Get(url, "application/octet-stream"))
        using (var s = r.GetResponseStream())
        using (var m = new MemoryStream()) {
            byte[] buf = new byte[81920];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0) {
                m.Write(buf, 0, n);
                if (m.Length > MaxBytes) throw new IOException("arquivo grande demais");
            }
            data = m.ToArray();
        }
        string got;
        using (var h = SHA256.Create()) got = BitConverter.ToString(h.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
        if (got != sha256) throw new IOException("o arquivo baixado não confere (SHA-256 diferente); nada foi trocado");
        return data;
    }

    // atualiza Interface\AddOns\WowPilot em cada variação que já tem o addon; devolve os nomes das variações
    public static List<string> UpdateAddon(byte[] zip, List<Flavor> flavors) {
        var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        using (var z = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read)) {
            foreach (ZipArchiveEntry e in z.Entries) {
                string name = e.FullName.Replace('\\', '/');
                if (!name.StartsWith("WowPilot/") || name.EndsWith("/")) continue;
                string rel = name.Substring("WowPilot/".Length);
                if (rel.Length == 0 || rel.Contains("..") || rel.Contains(":") || rel.StartsWith("/")) continue;
                using (var s = e.Open()) using (var m = new MemoryStream()) { s.CopyTo(m); files[rel] = m.ToArray(); }
            }
        }
        if (!files.ContainsKey("WowPilot.toc")) throw new IOException("o pacote do addon não tem o WowPilot.toc");
        var done = new List<string>();
        foreach (Flavor f in flavors) {
            string dest = AddonInstaller.DirOf(f);
            if (!File.Exists(Path.Combine(dest, "WowPilot.toc")) || AddonInstaller.IsGitClone(dest)) continue;
            AddonInstaller.Write(dest, files);
            done.Add(f.Name);
        }
        return done;
    }

    // troca o .exe em uso: atual → .old, novo no lugar
    public static void ReplaceExe(string exe, byte[] data) {
        string tmp = exe + ".new", old = exe + ".old";
        File.WriteAllBytes(tmp, data);
        if (File.Exists(old)) File.Delete(old);
        File.Move(exe, old);
        try { File.Move(tmp, exe); }
        catch { File.Move(old, exe); throw; }   // desfaz: o programa continua o mesmo
    }

    // apaga o .old que sobrou da última atualização (chamado ao abrir)
    public static void Cleanup(string exe) {
        try { if (File.Exists(exe + ".old")) File.Delete(exe + ".old"); } catch { }
    }

    // abre o .exe novo, que espera este processo fechar antes de assumir
    public static void Restart(string exe) {
        Process.Start(new ProcessStartInfo(exe, "--after-update " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
    }

    static HttpWebResponse Get(string url, string accept) {
        var req = (HttpWebRequest)WebRequest.Create(url);
        req.UserAgent = "WowPilotSync/" + Http.Version;
        req.Accept = accept;
        req.Timeout = req.ReadWriteTimeout = 60000;
        req.AllowAutoRedirect = true;
        return (HttpWebResponse)req.GetResponse();
    }
}

// O addon vem embutido no .exe (mesma versão do programa). Ao abrir, o programa instala o addon no Retail e no
// WoW: Forever onde ele ainda não existe e atualiza onde está numa versão mais antiga. Pastas que são clone do git
// (quem desenvolve) e versões mais novas instaladas à mão ficam como estão.
public static class AddonInstaller {
    static readonly string[] Files = { "WowPilot.toc", "WowPilot.lua", "WowPilotLive.lua", "WowPilotPulse.lua", "WowPilotGuides.lua" };
    static readonly string[] Products = { "wow", "wowf" };   // os jogos que o addon suporta

    public static string DirOf(Flavor f) { return Path.Combine(f.Dir, "Interface", "AddOns", "WowPilot"); }

    public static bool IsGitClone(string dir) {
        return Directory.Exists(Path.Combine(dir, ".git")) || File.Exists(Path.Combine(dir, ".git"));
    }

    // arquivos do addon embutidos no .exe (client\build.cmd: /resource:...,addon.<arquivo>)
    public static Dictionary<string, byte[]> Embedded() {
        var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        var asm = typeof(AddonInstaller).Assembly;
        foreach (string name in Files) {
            using (Stream s = asm.GetManifestResourceStream("addon." + name)) {
                if (s == null) return null;
                using (var m = new MemoryStream()) { s.CopyTo(m); files[name] = m.ToArray(); }
            }
        }
        return files;
    }

    public static Version TocVersion(byte[] toc) {
        foreach (string line in System.Text.Encoding.UTF8.GetString(toc).Split('\n')) {
            string l = line.Trim();
            if (!l.StartsWith("## Version:")) continue;
            try { return new Version(l.Substring("## Version:".Length).Trim()); } catch { return null; }
        }
        return null;
    }

    // instala/atualiza; devolve uma linha por variação que mudou ou ficou de fora (para o log)
    public static List<string> Sync(List<Flavor> flavors) {
        var log = new List<string>();
        Dictionary<string, byte[]> files = Embedded();
        if (files == null) return log;
        Version mine = TocVersion(files["WowPilot.toc"]);
        foreach (Flavor f in flavors) {
            if (Array.IndexOf(Products, (f.Product ?? "").ToLowerInvariant()) < 0) continue;
            string dest = DirOf(f), toc = Path.Combine(dest, "WowPilot.toc");
            try {
                if (!File.Exists(toc)) {
                    if (!Directory.Exists(Path.Combine(f.Dir, "Interface", "AddOns")) && !Directory.Exists(Path.Combine(f.Dir, "WTF"))) continue;
                    Write(dest, files);
                    log.Add("addon " + mine + " instalado no " + f.Name + " (se o jogo estiver aberto, feche e abra de novo)");
                    continue;
                }
                if (IsGitClone(dest)) continue;
                Version have = TocVersion(File.ReadAllBytes(toc));
                if (have != null && mine != null && have >= mine) continue;
                Write(dest, files);
                log.Add("addon do " + f.Name + " atualizado para " + mine + " (no jogo: /reload)");
            } catch (Exception e) {
                log.Add("não consegui instalar o addon no " + f.Name + ": " + e.Message);
            }
        }
        return log;
    }

    // grava arquivo a arquivo (.new e troca), para o jogo nunca ler um arquivo pela metade
    public static void Write(string dest, Dictionary<string, byte[]> files) {
        foreach (var kv in files) {
            string path = Path.Combine(dest, kv.Key.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllBytes(path + ".new", kv.Value);
            if (File.Exists(path)) File.Delete(path);
            File.Move(path + ".new", path);
        }
    }
}
}
