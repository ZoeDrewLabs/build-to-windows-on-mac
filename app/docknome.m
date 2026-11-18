// docknome — faz o Dock e a barra de menus mostrarem o nome do programa de Windows (PEAK, Steam…)
// em vez de "wine". Carregada no Wine por DYLD_INSERT_LIBRARIES (o motor é x86_64 e não é "hardened").
//
// Como: cada programa do Windows é um processo do Wine; o Wine reescreve os argumentos do processo
// com o caminho do .exe ("C:\...\PEAK.exe"). Lemos isso, escolhemos o nome e, quando o processo vira
// app de interface, avisamos o LaunchServices (a mesma chamada que o Java usa para -Xdock:name).
//
// Nome: 1) tabela ZOG_DOCK_MAP (arquivo "exe<TAB>Nome", ex.: steamwebhelper.exe → Steam);
//       2) se o .exe tem o mesmo nome da pasta dele (Steam\steam.exe) → o nome da pasta;
//       3) o nome do .exe sem a extensão (PEAK.exe → PEAK).
#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <unistd.h>

// LaunchServices (privado, estável há anos; o Java usa)
extern CFTypeRef _LSGetCurrentApplicationASN(void);
extern OSStatus _LSSetApplicationInformationItem(int session, CFTypeRef asn, CFStringRef key,
                                                 CFStringRef value, CFDictionaryRef *info);
extern CFStringRef _kLSDisplayNameKey;

static NSString *windowsExe(void) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, getpid()};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buf = malloc(size);
    if (!buf) return nil;
    NSString *found = nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0) {
        // formato: int argc, caminho do executável, \0s, argv[0]…argv[argc-1]
        char *p = buf + sizeof(int), *end = buf + size;
        while (p < end && *p) p++;            // pula o caminho do executável
        while (p < end && !*p) p++;           // pula os \0
        while (p < end && !found) {
            NSString *s = [NSString stringWithUTF8String:p];
            NSRange r = [s rangeOfString:@".exe" options:NSCaseInsensitiveSearch];
            if (r.location != NSNotFound) found = [s substringToIndex:NSMaxRange(r)];
            p += strlen(p) + 1;
        }
    }
    free(buf);
    return found;
}

static NSString *chooseName(void) {
    NSString *exe = windowsExe();
    if (!exe) return nil;
    NSString *norm = [exe stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *file = norm.lastPathComponent;                       // PEAK.exe
    NSString *base = file.stringByDeletingPathExtension;            // PEAK
    NSString *folder = norm.stringByDeletingLastPathComponent.lastPathComponent;

    const char *map = getenv("ZOG_DOCK_MAP");
    if (map) {
        NSString *text = [NSString stringWithContentsOfFile:@(map) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"#"]) continue;
            NSArray *f = [line componentsSeparatedByString:@"\t"];
            if (f.count >= 2 && [f[0] caseInsensitiveCompare:file] == NSOrderedSame && [f[1] length]) return f[1];
        }
    }
    if (folder.length && [folder caseInsensitiveCompare:base] == NSOrderedSame) return folder;
    // programas internos do Wine não ganham nome (wineboot, services, explorer…)
    NSString *low = file.lowercaseString;
    for (NSString *skip in @[@"wineboot.exe", @"services.exe", @"winedevice.exe", @"plugplay.exe",
                             @"svchost.exe", @"explorer.exe", @"rpcss.exe", @"start.exe", @"conhost.exe"])
        if ([low isEqualToString:skip]) return nil;
    return base;
}

static void applyName(NSString *name) {
    CFTypeRef asn = _LSGetCurrentApplicationASN();
    if (asn && name.length)
        _LSSetApplicationInformationItem(-2, asn, _kLSDisplayNameKey, (__bridge CFStringRef)name, NULL);
}

// O Dock e a barra de menus guardam o nome com que o processo se apresenta ao macOS na PRIMEIRA vez
// (o CFBundleName do bundle principal; para o Wine, que não tem bundle, vira o nome do executável:
// "wine"). Então troca esse nome AQUI, no carregamento, antes de o Wine criar o NSApplication.
static void renameMainBundle(NSString *name) {
    CFBundleRef main = CFBundleGetMainBundle();
    if (!main) return;
    CFDictionaryRef info = CFBundleGetInfoDictionary(main);
    if (info && CFGetTypeID(info) == CFDictionaryGetTypeID()) {
        // o dicionário do bundle principal é mutável por dentro; é o truque clássico de "renomear o app"
        CFMutableDictionaryRef m = (CFMutableDictionaryRef)info;
        CFDictionarySetValue(m, kCFBundleNameKey, (__bridge CFStringRef)name);
        CFDictionarySetValue(m, CFSTR("CFBundleDisplayName"), (__bridge CFStringRef)name);
        // NÃO mexer em CFBundleExecutable: o Wine usa o caminho do executável e trava sem ele
    }
    [[NSProcessInfo processInfo] setProcessName:name];
}

__attribute__((constructor)) static void docknome_init(void) {
    if (getenv("ZOG_DOCK_OFF")) return;
    NSString *name = chooseName();
    if (!name) return;
    renameMainBundle(name);
    // O Dock cria o ícone quando o processo vira "Foreground" (ao abrir a 1ª janela) e usa o nome que o
    // LaunchServices tem NAQUELE momento. O registro (ainda "BackgroundOnly") acontece antes; vigia numa
    // fila de fundo (não depende do run loop do Wine) e dá o nome assim que o registro existir.
    dispatch_queue_t q = dispatch_queue_create("docknome.watch", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    __block int ticks = 0, applied = 0;
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        ticks++;
        if (_LSGetCurrentApplicationASN()) {
            applyName(name);
            applied++;
        }
        // reaplica por ~2 s depois do registro e desiste em 2 minutos (processos sem janela)
        if (applied > 100 || ticks > 6000) dispatch_source_cancel(t);
    });
    dispatch_resume(t);
    // O processo só vira app do Dock quando o Wine abre a primeira janela; tenta ao terminar de
    // iniciar e mais algumas vezes depois (o registro no LaunchServices pode chegar atrasado).
    [[NSNotificationCenter defaultCenter] addObserverForName:@"NSApplicationDidFinishLaunchingNotification"
        object:nil queue:nil usingBlock:^(NSNotification *n) { applyName(name); }];
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyName(name); });
    }
}
