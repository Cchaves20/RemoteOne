import '../models/stream_quality.dart';

/// Idioma do app: segue o sistema, ou fixo num dos cinco suportados.
enum AppLanguage { system, ptBr, en, zh, fr, es }

/// Textos do app nos cinco idiomas. Uma única fonte, sem geração de código.
/// Cada texto é `_t(pt, en, zh, fr, es)`. Acesse por `state.t` (reconstrói ao
/// trocar o idioma). O idioma `system` é resolvido antes de chegar aqui.
class Strings {
  const Strings(this.lang);
  final AppLanguage lang;

  String _t(String pt, String en, String zh, String fr, String es) =>
      switch (lang) {
        AppLanguage.ptBr => pt,
        AppLanguage.zh => zh,
        AppLanguage.fr => fr,
        AppLanguage.es => es,
        _ => en,
      };

  // Comuns
  String get cancel => _t('Cancelar', 'Cancel', '取消', 'Annuler', 'Cancelar');
  String get save => _t('Salvar', 'Save', '保存', 'Enregistrer', 'Guardar');
  String get remove => _t('Remover', 'Remove', '移除', 'Retirer', 'Quitar');
  String get delete => _t('Excluir', 'Delete', '删除', 'Supprimer', 'Eliminar');
  String get enable => _t('Ativar', 'Enable', '启用', 'Activer', 'Activar');
  String get retry => _t('Tentar de novo', 'Try again', '重试', 'Réessayer', 'Reintentar');
  String get disable => _t('Desativar', 'Disable', '停用', 'Désactiver', 'Desactivar');

  // Login
  String get signInTitle => _t('Entrar', 'Sign in', '登录', 'Se connecter', 'Entrar');
  String get createAccountTitle =>
      _t('Criar conta', 'Create account', '创建账户', 'Créer un compte', 'Crear cuenta');
  String get email => _t('E-mail', 'Email', '邮箱', 'E-mail', 'Correo');
  String get password => _t('Senha', 'Password', '密码', 'Mot de passe', 'Contraseña');
  String get twoFactorCode => _t('Código de verificação (2FA)', 'Verification code (2FA)',
      '验证码 (2FA)', 'Code de vérification (2FA)', 'Código de verificación (2FA)');
  String get twoFactorCodeHint => _t('Do seu app autenticador', 'From your authenticator app',
      '来自身份验证器应用', "De votre application d'authentification", 'De tu app de autenticación');
  String get server => _t('Servidor', 'Server', '服务器', 'Serveur', 'Servidor');
  String get serverHint => 'Ex.: http://192.168.0.10:8000';
  String get signInButton => _t('Entrar', 'Sign in', '登录', 'Se connecter', 'Entrar');
  String get createAccountButton =>
      _t('Cadastrar', 'Sign up', '注册', "S'inscrire", 'Registrarse');
  String get haveAccount => _t('Já tenho conta', 'I already have an account', '我已有账户',
      "J'ai déjà un compte", 'Ya tengo una cuenta');
  String get createOne => _t('Criar uma conta', 'Create an account', '创建账户',
      'Créer un compte', 'Crear una cuenta');
  String get invalidCode => _t('Código inválido. Tente de novo.', 'Invalid code. Try again.',
      '验证码无效，请重试。', 'Code invalide. Réessayez.', 'Código inválido. Inténtalo de nuevo.');

  // Dispositivos
  String get myComputers =>
      _t('Meus computadores', 'My computers', '我的电脑', 'Mes ordinateurs', 'Mis equipos');
  String get settings =>
      _t('Configurações', 'Settings', '设置', 'Paramètres', 'Ajustes');
  String get pairComputer => _t('Parear computador', 'Pair computer', '配对电脑',
      "Associer l'ordinateur", 'Vincular equipo');
  String get codeShownOnComputer => _t('Código exibido no computador',
      'Code shown on the computer', '电脑上显示的代码', "Code affiché sur l'ordinateur",
      'Código mostrado en el equipo');
  String get pair => _t('Parear', 'Pair', '配对', 'Associer', 'Vincular');
  String get computerPaired => _t('Computador pareado!', 'Computer paired!', '电脑已配对！',
      'Ordinateur associé !', '¡Equipo vinculado!');
  String get noComputers => _t(
      'Nenhum computador pareado.\nToque em + e informe o código exibido pelo agente.',
      'No computers paired.\nTap + and enter the code shown by the agent.',
      '没有已配对的电脑。\n点击 + 并输入代理显示的代码。',
      "Aucun ordinateur associé.\nAppuyez sur + et saisissez le code affiché par l'agent.",
      'No hay equipos vinculados.\nToca + e introduce el código que muestra el agente.');
  String get online => _t('Online', 'Online', '在线', 'En ligne', 'En línea');
  String get offline => _t('Offline', 'Offline', '离线', 'Hors ligne', 'Desconectado');
  String get wake => _t('Ligar (Wake-on-LAN)', 'Turn on (Wake-on-LAN)', '开机 (Wake-on-LAN)',
      'Allumer (Wake-on-LAN)', 'Encender (Wake-on-LAN)');
  String get control => _t('Controlar', 'Control', '控制', 'Contrôler', 'Controlar');
  String get rename => _t('Renomear', 'Rename', '重命名', 'Renommer', 'Renombrar');
  String get shutdown => _t('Desligar', 'Shut down', '关机', 'Éteindre', 'Apagar');
  String get restart => _t('Reiniciar', 'Restart', '重启', 'Redémarrer', 'Reiniciar');
  String get suspend => _t('Suspender', 'Sleep', '睡眠', 'Veille', 'Suspender');
  String get renameComputer => _t('Renomear computador', 'Rename computer', '重命名电脑',
      "Renommer l'ordinateur", 'Renombrar equipo');
  String get name => _t('Nome', 'Name', '名称', 'Nom', 'Nombre');
  String get nameUpdated =>
      _t('Nome atualizado.', 'Name updated.', '名称已更新。', 'Nom mis à jour.', 'Nombre actualizado.');
  String get removeComputer => _t('Remover computador', 'Remove computer', '移除电脑',
      "Retirer l'ordinateur", 'Quitar equipo');
  String unlinkConfirm(String device) => _t(
      'Desvincular "$device" da sua conta?',
      'Unlink "$device" from your account?',
      '将"$device"从你的账户解绑？',
      'Dissocier « $device » de votre compte ?',
      '¿Desvincular «$device» de tu cuenta?');
  String get computerRemoved => _t('Computador removido.', 'Computer removed.', '电脑已移除。',
      'Ordinateur retiré.', 'Equipo eliminado.');
  String powerLabel(String action) => switch (action) {
        'shutdown' => shutdown,
        'restart' => restart,
        _ => suspend,
      };
  String powerConfirm(String action, String device) => _t(
      '${powerLabel(action)} "$device" agora?',
      '${powerLabel(action)} "$device" now?',
      '现在${powerLabel(action)}"$device"？',
      '${powerLabel(action)} « $device » maintenant ?',
      '¿${powerLabel(action)} «$device» ahora?');
  String powerSent(String action) => _t(
      '${powerLabel(action)} enviado.',
      '${powerLabel(action)} sent.',
      '已发送：${powerLabel(action)}。',
      '${powerLabel(action)} envoyé.',
      '${powerLabel(action)} enviado.');
  String get wakeSent => _t(
      'Sinal enviado. O computador deve ligar em instantes.',
      'Signal sent. The computer should turn on shortly.',
      '信号已发送。电脑应该很快开机。',
      "Signal envoyé. L'ordinateur devrait s'allumer sous peu.",
      'Señal enviada. El equipo debería encenderse en breve.');

  // Aplicativos do computador
  String get apps => _t('Aplicativos', 'Apps', '应用', 'Applications', 'Aplicaciones');
  String get appsDesktop => _t('Área de trabalho', 'Desktop', '桌面',
      'Bureau', 'Escritorio');
  String get appsInstalled =>
      _t('Instalados', 'Installed', '已安装', 'Installées', 'Instaladas');
  String get appsRunning => _t('Abertos', 'Running', '运行中', 'Ouvertes', 'Abiertas');
  String get appsSearch => _t('Buscar aplicativo', 'Search app', '搜索应用',
      'Rechercher une application', 'Buscar aplicación');
  String get appsQuerying => _t(
      'Consultando o computador…',
      'Asking the computer…',
      '正在查询电脑…',
      "Interrogation de l'ordinateur…",
      'Consultando el equipo…');
  String get appsEmptyDesktop => _t(
      'Nenhum atalho na área de trabalho do computador.',
      'No shortcuts on the computer desktop.',
      '电脑桌面上没有快捷方式。',
      "Aucun raccourci sur le bureau de l'ordinateur.",
      'No hay accesos directos en el escritorio del equipo.');
  String get appsEmptyInstalled => _t(
      'Nenhum aplicativo encontrado no computador.',
      'No apps found on the computer.',
      '在电脑上没有找到应用。',
      "Aucune application trouvée sur l'ordinateur.",
      'No se encontraron aplicaciones en el equipo.');
  String get appsEmptyRunning => _t(
      'Nenhum aplicativo aberto no momento.',
      'No apps are open right now.',
      '当前没有打开的应用。',
      'Aucune application ouverte pour le moment.',
      'No hay aplicaciones abiertas ahora mismo.');
  String appOpening(String name) => _t('Abrindo $name…', 'Opening $name…',
      '正在打开 $name…', 'Ouverture de $name…', 'Abriendo $name…');
  String appClosed(String name) => _t('$name encerrado.', '$name closed.',
      '$name 已关闭。', '$name fermé.', '$name cerrado.');
  String get appClose => _t('Encerrar', 'Close', '关闭', 'Fermer', 'Cerrar');
  String appCloseConfirm(String name) => _t(
      'Encerrar "$name" no computador?',
      'Close "$name" on the computer?',
      '在电脑上关闭"$name"？',
      'Fermer « $name » sur l\'ordinateur ?',
      '¿Cerrar «$name» en el equipo?');
  String get appsHint => _t(
      'Toque para abrir. A lista vem do computador, pode levar alguns segundos.',
      'Tap to open. The list comes from the computer and may take a few seconds.',
      '点击打开。列表来自电脑，可能需要几秒钟。',
      "Touchez pour ouvrir. La liste vient de l'ordinateur et peut prendre quelques secondes.",
      'Toca para abrir. La lista viene del equipo y puede tardar unos segundos.');

  // Configurações
  String get appearance => _t('Aparência', 'Appearance', '外观', 'Apparence', 'Apariencia');
  String get screenQuality => _t('Qualidade da tela', 'Screen quality', '画面质量',
      "Qualité de l'écran", 'Calidad de pantalla');
  String get security => _t('Segurança', 'Security', '安全', 'Sécurité', 'Seguridad');
  String get account => _t('Conta', 'Account', '账户', 'Compte', 'Cuenta');
  String get help => _t('Ajuda', 'Help', '帮助', 'Aide', 'Ayuda');
  String get about => _t('Sobre', 'About', '关于', 'À propos', 'Acerca de');
  String get language => _t('Idioma', 'Language', '语言', 'Langue', 'Idioma');
  String get languageSystem => _t('Automático (sistema)', 'Automatic (system)', '自动（系统）',
      'Automatique (système)', 'Automático (sistema)');
  String get themeAuto => _t('Automático (sistema)', 'Automatic (system)', '自动（系统）',
      'Automatique (système)', 'Automático (sistema)');
  String get themeLight => _t('Claro', 'Light', '浅色', 'Clair', 'Claro');
  String get themeDark => _t('Escuro', 'Dark', '深色', 'Sombre', 'Oscuro');
  /// Rótulo curto para o seletor segmentado (evita quebrar em telas estreitas).
  String get autoShort => _t('Auto', 'Auto', '自动', 'Auto', 'Auto');
  String get faceIdLock => _t('Bloquear com Face ID / biometria',
      'Lock with Face ID / biometrics', '使用 Face ID / 生物识别锁定',
      'Verrouiller avec Face ID / biométrie', 'Bloquear con Face ID / biometría');
  String get faceIdLockSub => _t('Pede biometria ao abrir o app',
      'Asks for biometrics when opening the app', '打开应用时要求生物识别',
      "Demande la biométrie à l'ouverture de l'app", 'Pide biometría al abrir la app');
  String get twoFactor => _t('Verificação em duas etapas (2FA)', 'Two-step verification (2FA)',
      '两步验证 (2FA)', 'Vérification en deux étapes (2FA)', 'Verificación en dos pasos (2FA)');
  String get appLocked =>
      _t('RemoteOne bloqueado', 'RemoteOne locked', 'RemoteOne 已锁定', 'RemoteOne verrouillé', 'RemoteOne bloqueado');
  String get unlock => _t('Desbloquear', 'Unlock', '解锁', 'Déverrouiller', 'Desbloquear');
  String get twoFactorSub => _t('Pede um código do autenticador ao entrar',
      'Asks for an authenticator code at sign-in', '登录时要求身份验证器代码',
      "Demande un code d'authentification à la connexion",
      'Pide un código del autenticador al entrar');
  String get changeEmail =>
      _t('Alterar e-mail', 'Change email', '更改邮箱', "Changer l'e-mail", 'Cambiar correo');
  String get changePassword => _t('Alterar senha', 'Change password', '更改密码',
      'Changer le mot de passe', 'Cambiar contraseña');
  String get signOut => _t('Sair', 'Sign out', '退出', 'Se déconnecter', 'Salir');
  String get deleteAccount => _t('Excluir conta', 'Delete account', '删除账户',
      'Supprimer le compte', 'Eliminar cuenta');
  String get howToControl => _t('Como controlar (gestos)', 'How to control (gestures)',
      '如何控制（手势）', 'Comment contrôler (gestes)', 'Cómo controlar (gestos)');
  String get howToControlSub => _t('Toque, arrastar, segurar, rolar', 'Tap, drag, hold, scroll',
      '点按、拖动、长按、滚动', 'Toucher, glisser, maintenir, défiler', 'Tocar, arrastrar, mantener, desplazar');
  String get turnOnPc => _t('Ligar o PC (Wake-on-LAN)', 'Turn on the PC (Wake-on-LAN)',
      '开机 (Wake-on-LAN)', 'Allumer le PC (Wake-on-LAN)', 'Encender el PC (Wake-on-LAN)');
  String get turnOnPcSub => _t('Como acordar um computador desligado',
      'How to wake a computer that is off', '如何唤醒已关机的电脑',
      'Comment réveiller un ordinateur éteint', 'Cómo despertar un equipo apagado');
  String version(String v) =>
      _t('Versão $v', 'Version $v', '版本 $v', 'Version $v', 'Versión $v');

  String qualityLabel(StreamQuality q) => switch (q) {
        StreamQuality.economico => _t('Econômico', 'Economy', '省流', 'Économique', 'Económica'),
        StreamQuality.equilibrado =>
          _t('Equilibrado', 'Balanced', '均衡', 'Équilibré', 'Equilibrada'),
        StreamQuality.nitido => _t('Nítido', 'Sharp', '清晰', 'Net', 'Nítida'),
      };
  String qualitySubtitle(StreamQuality q) => _t(
      '${q.fps} fps · até ${q.maxWidth}px · qualidade ${q.quality}',
      '${q.fps} fps · up to ${q.maxWidth}px · quality ${q.quality}',
      '${q.fps} fps · 最大 ${q.maxWidth}px · 质量 ${q.quality}',
      "${q.fps} fps · jusqu'à ${q.maxWidth}px · qualité ${q.quality}",
      '${q.fps} fps · hasta ${q.maxWidth}px · calidad ${q.quality}');

  /// Mostrado no lugar do contador quando a tela do computador está parada —
  /// o agente para de enviar frames idênticos, então 0 fps é o esperado.
  String get screenStill =>
      _t('tela parada', 'screen still', '画面静止', 'écran fixe', 'pantalla fija');

  /// Mostrado no lugar do contador quando a tela chega por vídeo (WebRTC): não
  /// há frames JPEG para contar, então o número ficaria em 0 por definição.
  String get videoMode => _t('vídeo', 'video', '视频', 'vidéo', 'vídeo');

  /// Vídeo **e** entrada indo direto ao computador, sem passar pelo servidor.
  /// Vale distinguir: é o estado em que o toque tem a menor latência possível.
  String get videoDirectMode =>
      _t('direto', 'direct', '直连', 'direct', 'directo');

  /// Aviso quando o vídeo não entra: a tela segue no modo antigo, então sem
  /// dizer nada o usuário nem saberia que houve uma tentativa.
  String get videoUnavailable => _t(
      'Vídeo em alta eficiência indisponível; usando o modo antigo.',
      'High-efficiency video unavailable; using the old mode.',
      '高效视频不可用，改用旧模式。',
      "Vidéo haute efficacité indisponible ; retour à l'ancien mode.",
      'Vídeo de alta eficiencia no disponible; usando el modo anterior.');

  // Preferência do vídeo por WebRTC
  String get webrtcVideo =>
      _t('Vídeo em alta eficiência', 'High-efficiency video', '高效视频',
          'Vidéo haute efficacité', 'Vídeo de alta eficiencia');
  String get webrtcVideoSub => _t(
      'Usa muito menos internet. Se der problema, desligue para voltar ao modo antigo.',
      'Uses far less data. If it misbehaves, turn it off to go back to the old mode.',
      '流量消耗大幅降低。如出现问题，可关闭以恢复旧模式。',
      "Consomme beaucoup moins de données. En cas de problème, désactivez pour revenir à l'ancien mode.",
      'Consume mucho menos datos. Si falla, desactívalo para volver al modo anterior.');

  // Sugestões no teclado
  String get suggestions => _t('Sugestões de palavra', 'Word suggestions',
      '词语建议', 'Suggestions de mots', 'Sugerencias de palabras');
  String get suggestionsSub => _t(
      'Mostra palavras acima do teclado. Nunca corrige sozinho: só troca se você tocar.',
      'Shows words above the keyboard. Never corrects on its own: it only changes if you tap.',
      '在键盘上方显示词语。不会自动更正：只有点击才会替换。',
      "Affiche des mots au-dessus du clavier. Ne corrige jamais tout seul : rien ne change sans un appui.",
      'Muestra palabras sobre el teclado. Nunca corrige solo: solo cambia si tocas.');

  // Arquivos
  String get files => _t('Arquivos', 'Files', '文件', 'Fichiers', 'Archivos');
  String get refresh =>
      _t('Atualizar', 'Refresh', '刷新', 'Actualiser', 'Actualizar');
  String get filesUp =>
      _t('Pasta acima', 'Up one folder', '上一级', 'Dossier parent', 'Carpeta superior');
  String get filesEmpty =>
      _t('Pasta vazia', 'Empty folder', '空文件夹', 'Dossier vide', 'Carpeta vacía');
  String get filesBackToHome => _t('Voltar ao início', 'Back to start', '回到起点',
      'Revenir au début', 'Volver al inicio');
  String get fileBring =>
      _t('Trazer para o celular', 'Bring to phone', '下载到手机',
          'Récupérer sur le téléphone', 'Traer al teléfono');
  String get fileSend =>
      _t('Enviar arquivo', 'Send file', '发送文件', 'Envoyer un fichier', 'Enviar archivo');
  String get fileTransferring =>
      _t('Transferindo…', 'Transferring…', '传输中…', 'Transfert…', 'Transfiriendo…');
  String fileSentTo(String path) => _t(
      'Salvo no computador em $path',
      'Saved on the computer at $path',
      '已保存到电脑：$path',
      "Enregistré sur l'ordinateur dans $path",
      'Guardado en el equipo en $path');
  String get fileDownloadFailed => _t('Não consegui trazer o arquivo',
      "Couldn't bring the file", '无法下载该文件',
      'Impossible de récupérer le fichier', 'No se pudo traer el archivo');
  String get fileUploadFailed => _t('Não consegui enviar o arquivo',
      "Couldn't send the file", '无法发送该文件',
      "Impossible d'envoyer le fichier", 'No se pudo enviar el archivo');

  // Painel de métricas do computador
  String get systemPanel =>
      _t('Computador', 'Computer', '电脑', 'Ordinateur', 'Equipo');
  String get systemCpu => _t('CPU', 'CPU', '处理器', 'Processeur', 'CPU');
  String get systemMemory =>
      _t('Memória', 'Memory', '内存', 'Mémoire', 'Memoria');
  String get systemDisk => _t('Disco', 'Disk', '磁盘', 'Disque', 'Disco');
  String get systemUptime =>
      _t('Ligado há', 'Powered on for', '已开机', 'Allumé depuis', 'Encendido hace');
  /// Abreviações de tempo. Curtas de propósito: cabem no painel retraído.
  String get unitDay => _t('d', 'd', '天', 'j', 'd');
  String get unitHour => _t('h', 'h', '时', 'h', 'h');
  String get unitMinute => _t('min', 'min', '分', 'min', 'min');
  String get systemUnavailable => _t(
      'Não consegui medir agora.',
      "Couldn't measure right now.",
      '暂时无法测量。',
      'Mesure impossible pour le moment.',
      'No se pudo medir ahora.');

  // Controle de mídia
  String get mediaPanel => _t('Mídia', 'Media', '媒体', 'Média', 'Medios');
  String get mediaPlayPause =>
      _t('Tocar ou pausar', 'Play or pause', '播放/暂停', 'Lire ou mettre en pause',
          'Reproducir o pausar');
  String get mediaNext =>
      _t('Próxima', 'Next', '下一首', 'Suivant', 'Siguiente');
  String get mediaPrevious =>
      _t('Anterior', 'Previous', '上一首', 'Précédent', 'Anterior');
  String get mediaVolumeUp =>
      _t('Aumentar volume', 'Volume up', '音量加', 'Augmenter le volume', 'Subir volumen');
  String get mediaVolumeDown =>
      _t('Diminuir volume', 'Volume down', '音量减', 'Baisser le volume', 'Bajar volumen');
  String get mediaMute =>
      _t('Silenciar', 'Mute', '静音', 'Couper le son', 'Silenciar');

  // Som do computador no telefone
  String get audioOn => _t('Ouvir o computador', 'Listen to the computer',
      '收听电脑声音', "Écouter l'ordinateur", 'Escuchar el equipo');
  String get audioOff => _t('Parar de ouvir', 'Stop listening', '停止收听',
      "Arrêter d'écouter", 'Dejar de escuchar');
  String get audioNeedsVideo => _t(
      'O som precisa da conexão direta de vídeo, que ainda não está de pé.',
      'Sound needs the direct video connection, which is not up yet.',
      '声音需要直连视频，目前尚未建立。',
      "Le son a besoin de la connexion vidéo directe, pas encore établie.",
      'El sonido necesita la conexión directa de vídeo, que aún no está lista.');

  String get videoDisabled => _t('vídeo direto desligado', 'direct video off',
      '直连视频已关闭', 'vidéo directe désactivée', 'vídeo directo desactivado');
  String get videoConnecting => _t('conectando vídeo…', 'connecting video…',
      '正在连接视频…', 'connexion vidéo…', 'conectando vídeo…');
  String get videoFailedShort => _t('vídeo direto falhou', 'direct video failed',
      '直连视频失败', 'échec de la vidéo directe', 'falló el vídeo directo');
  String get audioNeedsVideoEnabled => _t(
      'Ligue "Vídeo por WebRTC" nas configurações: o som viaja pela conexão direta.',
      'Turn on "WebRTC video" in settings: sound travels over the direct connection.',
      '请在设置中开启"WebRTC 视频"：声音通过直连传输。',
      'Activez « Vidéo WebRTC » dans les réglages : le son passe par la connexion directe.',
      'Activa "Vídeo por WebRTC" en ajustes: el sonido viaja por la conexión directa.');
  String get audioWaitVideo => _t(
      'A conexão direta de vídeo ainda está sendo montada. Tente em alguns segundos.',
      'The direct video connection is still being set up. Try again in a few seconds.',
      '直连视频仍在建立中，请稍后再试。',
      "La connexion vidéo directe est en cours d'établissement. Réessayez dans quelques secondes.",
      'La conexión directa de vídeo aún se está estableciendo. Inténtalo en unos segundos.');
  String get audioGainHint => _t(
      'Deixe o volume do computador no mínimo (sem silenciar) e recupere o volume aqui.',
      "Set the computer's volume to minimum (not muted) and bring the volume back here.",
      '把电脑音量调到最低（不要静音），在这里把音量补回来。',
      "Mettez le volume de l'ordinateur au minimum (sans couper) et récupérez le volume ici.",
      'Deja el volumen del equipo al mínimo (sin silenciar) y recupera el volumen aquí.');
  String get audioNoTrack => _t(
      'O computador não mandou som. Confira se o agente e o app estão na mesma versão.',
      "The computer didn't send any sound. Check that the agent and the app are on the same version.",
      '电脑没有发送声音。请确认代理和 App 版本一致。',
      "L'ordinateur n'a envoyé aucun son. Vérifiez que l'agent et l'app sont à jour.",
      'El equipo no envió sonido. Comprueba que el agente y la app estén en la misma versión.');

  // Área de transferência compartilhada
  String get clipboardTitle => _t('Área de transferência', 'Clipboard',
      '剪贴板', 'Presse-papiers', 'Portapapeles');
  String get clipboardOnComputer =>
      _t('No computador', 'On the computer', '电脑上', "Sur l'ordinateur",
          'En el equipo');
  String get clipboardEmpty =>
      _t('(vazia)', '(empty)', '（空）', '(vide)', '(vacío)');
  String get clipboardPull => _t('Trazer', 'Bring', '取回', 'Récupérer', 'Traer');
  String get clipboardPush => _t('Enviar', 'Send', '发送', 'Envoyer', 'Enviar');
  String get clipboardPulled => _t('Copiado no telefone.', 'Copied on the phone.',
      '已复制到手机。', 'Copié sur le téléphone.', 'Copiado en el teléfono.');
  String get clipboardPushed => _t('Copiado no computador.',
      'Copied on the computer.', '已复制到电脑。', "Copié sur l'ordinateur.",
      'Copiado en el equipo.');
  String get clipboardPhoneEmpty => _t(
      'Não há nada copiado no telefone.',
      'Nothing is copied on the phone.',
      '手机上没有已复制的内容。',
      "Rien n'est copié sur le téléphone.",
      'No hay nada copiado en el teléfono.');
  String get clipboardReceived => _t('Copiado do computador.',
      'Copied from the computer.', '已从电脑复制。', "Copié depuis l'ordinateur.",
      'Copiado desde el equipo.');
  String get clipboardSync => _t('Sincronizar automaticamente',
      'Sync automatically', '自动同步', 'Synchroniser automatiquement',
      'Sincronizar automáticamente');
  String get clipboardSyncSub => _t(
      'O que você copiar no computador aparece aqui na hora. Isso inclui senhas.',
      'Whatever you copy on the computer shows up here right away. That includes passwords.',
      '你在电脑上复制的内容会立即出现在这里，包括密码。',
      "Ce que vous copiez sur l'ordinateur apparaît ici aussitôt. Mots de passe compris.",
      'Lo que copies en el equipo aparece aquí al instante. Eso incluye contraseñas.');

  String clipboardFiles(int n) => _t(
      n == 1 ? '1 arquivo copiado' : '$n arquivos copiados',
      n == 1 ? '1 copied file' : '$n copied files',
      '已复制 $n 个文件',
      n == 1 ? '1 fichier copié' : '$n fichiers copiés',
      n == 1 ? '1 archivo copiado' : '$n archivos copiados');
  String clipboardBringing(String name) => _t(
      'Trazendo $name…', 'Bringing $name…', '正在获取 $name…',
      'Récupération de $name…', 'Trayendo $name…');
  String get clipboardIsFolder => _t('Pasta — baixe pelos arquivos',
      'Folder — use the file browser', '文件夹 — 请用文件浏览器',
      'Dossier — utilisez le navigateur de fichiers',
      'Carpeta — usa el explorador de archivos');
  String get clipboardTooBig => _t('Grande demais (máx. 100 MB)',
      'Too large (max 100 MB)', '太大（上限 100 MB）',
      'Trop volumineux (max 100 Mo)', 'Demasiado grande (máx. 100 MB)');

  String get filesShortcuts => _t('Pastas do computador', 'Computer folders',
      '电脑文件夹', "Dossiers de l'ordinateur", 'Carpetas del equipo');

  // Perfis de controle (barra seletora)
  String get profilesPanel => _t('Perfis', 'Profiles', '配置', 'Profils', 'Perfiles');
  String get profileSystem => _t('Sistema', 'System', '系统', 'Système', 'Sistema');
  String get profileVideo => _t('Vídeo', 'Video', '视频', 'Vidéo', 'Vídeo');
  String get profileBrowser =>
      _t('Navegador', 'Browser', '浏览器', 'Navigateur', 'Navegador');
  String get profileWork => _t('Trabalho', 'Work', '办公', 'Travail', 'Trabajo');
  String get profileSlides => _t('Apresentação', 'Presentation', '演示',
      'Présentation', 'Presentación');

  // Atalhos dos perfis
  String get actionSwitchWindow => _t('Trocar de janela', 'Switch window',
      '切换窗口', 'Changer de fenêtre', 'Cambiar de ventana');
  String get actionShowDesktop => _t('Mostrar a área de trabalho',
      'Show desktop', '显示桌面', 'Afficher le bureau', 'Mostrar el escritorio');
  String get actionFileExplorer => _t('Abrir o explorador de arquivos',
      'Open file explorer', '打开文件资源管理器', "Ouvrir l'explorateur de fichiers",
      'Abrir el explorador de archivos');
  String get actionTaskManager => _t('Gerenciador de tarefas', 'Task manager',
      '任务管理器', 'Gestionnaire des tâches', 'Administrador de tareas');
  String get actionSnapLeft => _t('Encaixar à esquerda', 'Snap left', '靠左分屏',
      'Ancrer à gauche', 'Ajustar a la izquierda');
  String get actionSnapRight => _t('Encaixar à direita', 'Snap right', '靠右分屏',
      'Ancrer à droite', 'Ajustar a la derecha');
  String get actionCloseWindow => _t('Fechar a janela', 'Close window', '关闭窗口',
      'Fermer la fenêtre', 'Cerrar la ventana');
  String get actionRewind =>
      _t('Voltar um pouco', 'Rewind', '快退', 'Reculer', 'Retroceder');
  String get actionForward =>
      _t('Avançar um pouco', 'Fast forward', '快进', 'Avancer', 'Adelantar');
  String get actionFullscreen =>
      _t('Tela cheia', 'Fullscreen', '全屏', 'Plein écran', 'Pantalla completa');
  String get actionExitFullscreen => _t('Sair da tela cheia', 'Exit fullscreen',
      '退出全屏', 'Quitter le plein écran', 'Salir de pantalla completa');
  String get actionNewTab =>
      _t('Nova aba', 'New tab', '新标签页', 'Nouvel onglet', 'Nueva pestaña');
  String get actionCloseTab => _t('Fechar a aba', 'Close tab', '关闭标签页',
      "Fermer l'onglet", 'Cerrar la pestaña');
  String get actionReopenTab => _t('Reabrir a aba fechada', 'Reopen closed tab',
      '重新打开标签页', "Rouvrir l'onglet fermé", 'Reabrir la pestaña cerrada');
  String get actionPageBack => _t('Voltar', 'Back', '后退', 'Retour', 'Atrás');
  String get actionPageForward =>
      _t('Avançar', 'Forward', '前进', 'Suivant', 'Adelante');
  String get actionReload =>
      _t('Atualizar a página', 'Reload page', '刷新页面', 'Actualiser la page',
          'Recargar la página');
  String get actionAddressBar => _t('Barra de endereço', 'Address bar', '地址栏',
      "Barre d'adresse", 'Barra de direcciones');
  String get actionUndo => _t('Desfazer', 'Undo', '撤销', 'Annuler', 'Deshacer');
  String get actionRedo => _t('Refazer', 'Redo', '重做', 'Rétablir', 'Rehacer');
  String get actionCopy => _t('Copiar', 'Copy', '复制', 'Copier', 'Copiar');
  String get actionPaste => _t('Colar', 'Paste', '粘贴', 'Coller', 'Pegar');
  String get actionFind => _t('Localizar', 'Find', '查找', 'Rechercher', 'Buscar');
  String get actionPrint =>
      _t('Imprimir', 'Print', '打印', 'Imprimer', 'Imprimir');
  String get actionStartSlides => _t('Começar do início', 'Start from beginning',
      '从头开始放映', 'Démarrer au début', 'Empezar desde el principio');
  String get actionNextSlide => _t('Próximo slide', 'Next slide', '下一张',
      'Diapositive suivante', 'Diapositiva siguiente');
  String get actionPreviousSlide => _t('Slide anterior', 'Previous slide',
      '上一张', 'Diapositive précédente', 'Diapositiva anterior');
  String get actionBlackScreen =>
      _t('Tela preta', 'Black screen', '黑屏', 'Écran noir', 'Pantalla negra');
  String get actionExitSlides => _t('Sair da apresentação', 'Exit presentation',
      '退出放映', 'Quitter la présentation', 'Salir de la presentación');

  // Diálogos de conta
  String get newEmail => _t('Novo e-mail', 'New email', '新邮箱', 'Nouvel e-mail', 'Nuevo correo');
  String get currentPassword => _t('Senha atual', 'Current password', '当前密码',
      'Mot de passe actuel', 'Contraseña actual');
  String get emailUpdated => _t('E-mail atualizado.', 'Email updated.', '邮箱已更新。',
      'E-mail mis à jour.', 'Correo actualizado.');
  String get newPasswordMin => _t('Nova senha (mín. 8 caracteres)',
      'New password (min. 8 characters)', '新密码（至少 8 个字符）',
      'Nouveau mot de passe (min. 8 caractères)', 'Nueva contraseña (mín. 8 caracteres)');
  String get passwordUpdated => _t('Senha atualizada.', 'Password updated.', '密码已更新。',
      'Mot de passe mis à jour.', 'Contraseña actualizada.');
  String get deleteAccountBody => _t(
      'Isso remove sua conta e todos os computadores pareados. A ação não pode ser desfeita.',
      'This deletes your account and all paired computers. This cannot be undone.',
      '这将删除你的账户和所有已配对的电脑。此操作无法撤销。',
      'Ceci supprime votre compte et tous les ordinateurs associés. Action irréversible.',
      'Esto elimina tu cuenta y todos los equipos vinculados. No se puede deshacer.');
  String get confirmPassword => _t('Confirme a senha', 'Confirm your password', '确认密码',
      'Confirmez le mot de passe', 'Confirma la contraseña');

  // 2FA
  String get twoFactorTitle => _t('Verificação em duas etapas', 'Two-step verification',
      '两步验证', 'Vérification en deux étapes', 'Verificación en dos pasos');
  String get twoFactorSteps => _t(
      '1. Instale um app autenticador (Google Authenticator, Microsoft Authenticator, etc.).\n'
          '2. Escaneie o QR Code abaixo — ou digite o código manual.\n'
          '3. Digite o código de 6 dígitos que o app mostrar para confirmar.',
      '1. Install an authenticator app (Google Authenticator, Microsoft Authenticator, etc.).\n'
          '2. Scan the QR code below — or type the manual code.\n'
          '3. Enter the 6-digit code the app shows to confirm.',
      '1. 安装身份验证器应用（Google Authenticator、Microsoft Authenticator 等）。\n'
          '2. 扫描下方二维码，或手动输入密钥。\n'
          '3. 输入应用显示的 6 位验证码以确认。',
      "1. Installez une app d'authentification (Google Authenticator, Microsoft Authenticator, etc.).\n"
          '2. Scannez le QR code ci-dessous — ou saisissez le code manuel.\n'
          "3. Saisissez le code à 6 chiffres affiché par l'app pour confirmer.",
      '1. Instala una app de autenticación (Google Authenticator, Microsoft Authenticator, etc.).\n'
          '2. Escanea el código QR de abajo — o escribe el código manual.\n'
          '3. Introduce el código de 6 dígitos que muestra la app para confirmar.');
  String manualCode(String secret) => _t('Código manual: $secret', 'Manual code: $secret',
      '手动密钥：$secret', 'Code manuel : $secret', 'Código manual: $secret');
  String get codeCopied =>
      _t('Código copiado.', 'Code copied.', '密钥已复制。', 'Code copié.', 'Código copiado.');
  String get sixDigitCode => _t('Código de 6 dígitos', '6-digit code', '6 位验证码',
      'Code à 6 chiffres', 'Código de 6 dígitos');
  String get twoFactorEnabled => _t('Verificação em duas etapas ativada.',
      'Two-step verification enabled.', '两步验证已启用。',
      'Vérification en deux étapes activée.', 'Verificación en dos pasos activada.');
  String get disableTwoFactor =>
      _t('Desativar 2FA', 'Disable 2FA', '停用 2FA', 'Désactiver la 2FA', 'Desactivar 2FA');
  String get disableTwoFactorBody => _t(
      'Confirme sua senha para desativar a verificação em duas etapas.',
      'Confirm your password to disable two-step verification.',
      '确认密码以停用两步验证。',
      'Confirmez votre mot de passe pour désactiver la vérification en deux étapes.',
      'Confirma tu contraseña para desactivar la verificación en dos pasos.');
  String get twoFactorDisabled => _t('Verificação em duas etapas desativada.',
      'Two-step verification disabled.', '两步验证已停用。',
      'Vérification en deux étapes désactivée.', 'Verificación en dos pasos desactivada.');

  // Tela de controle
  String get waitingScreen => _t('Aguardando a tela do computador...',
      'Waiting for the computer screen...', '正在等待电脑画面…',
      "En attente de l'écran de l'ordinateur…", 'Esperando la pantalla del equipo…');
  String get reconnecting =>
      _t('Reconectando…', 'Reconnecting…', '重新连接中…', 'Reconnexion…', 'Reconectando…');
  String get zoomHint => _t(
      'Modo lupa: use as setas para mover e + / − para ampliar.',
      'Magnifier: use the arrows to move and + / − to zoom.',
      '放大模式：用箭头移动，用 + / − 缩放。',
      'Loupe : utilisez les flèches pour déplacer et + / − pour zoomer.',
      'Lupa: usa las flechas para mover y + / − para ampliar.');
  String get zoomOut => _t('Reduzir', 'Zoom out', '缩小', 'Réduire', 'Reducir');
  String get zoomIn => _t('Ampliar', 'Zoom in', '放大', 'Agrandir', 'Ampliar');
  String get zoomFit =>
      _t('Tamanho normal', 'Fit to screen', '适应屏幕', "Ajuster à l'écran", 'Ajustar a pantalla');
  String get zoomExit => _t('Sair da lupa', 'Exit magnifier', '退出放大', 'Quitter la loupe', 'Salir de la lupa');
  String get zoomEnter => _t('Ampliar (lupa)', 'Magnify', '放大（放大镜）', 'Agrandir (loupe)', 'Ampliar (lupa)');

  // Tutorial de gestos
  String get howToControlTitle =>
      _t('Como controlar', 'How to control', '如何控制', 'Comment contrôler', 'Cómo controlar');
  String get gestureIntro => _t(
      'A tela do computador ocupa o celular inteiro e você controla como num touchscreen:',
      'The computer screen fills your phone and you control it like a touchscreen:',
      '电脑画面占满手机屏幕，你像操作触摸屏一样控制它：',
      "L'écran de l'ordinateur occupe tout le téléphone et vous le contrôlez comme un écran tactile :",
      'La pantalla del equipo ocupa todo el teléfono y la controlas como una pantalla táctil:');
  String get gestureGotIt => _t('Entendi', 'Got it', '明白了', 'Compris', 'Entendido');
  List<(String, String)> get gestures => [
        (
          _t('Tocar', 'Tap', '点按', 'Toucher', 'Tocar'),
          _t('Leva o cursor ao ponto tocado e dá um clique (botão esquerdo).',
              'Moves the cursor to the point and left-clicks.', '将光标移到触点并左键单击。',
              'Déplace le curseur au point touché et fait un clic gauche.',
              'Lleva el cursor al punto y hace clic izquierdo.'),
        ),
        (
          _t('Arrastar', 'Drag', '拖动', 'Glisser', 'Arrastrar'),
          _t('Move o cursor seguindo o seu dedo.', 'Moves the cursor following your finger.',
              '光标跟随手指移动。', 'Déplace le curseur en suivant votre doigt.',
              'Mueve el cursor siguiendo tu dedo.'),
        ),
        (
          _t('Duplo toque', 'Double tap', '双击', 'Double toucher', 'Doble toque'),
          _t(
              'Seleciona a palavra. Sem tirar o dedo do segundo toque, arraste para selecionar mais.',
              'Selects the word. Without lifting your finger on the second tap, drag to select more.',
              '选中该词。第二次点击时不抬起手指，拖动可继续选择。',
              'Sélectionne le mot. Sans lever le doigt au second toucher, glissez pour sélectionner plus.',
              'Selecciona la palabra. Sin levantar el dedo en el segundo toque, arrastra para seleccionar más.'),
        ),
        (
          _t('Segurar', 'Hold', '长按', 'Maintenir', 'Mantener'),
          _t('Clique com o botão direito (menu de contexto).', 'Right-click (context menu).',
              '右键单击（上下文菜单）。', 'Clic droit (menu contextuel).',
              'Clic derecho (menú contextual).'),
        ),
        (
          _t('Dois dedos', 'Two fingers', '两指', 'Deux doigts', 'Dos dedos'),
          _t('Rola a página para cima e para baixo.', 'Scrolls up and down.', '上下滚动页面。',
              'Fait défiler vers le haut et le bas.', 'Desplaza hacia arriba y abajo.'),
        ),
        (
          _t('Botão da lupa', 'Magnifier button', '放大镜按钮', 'Bouton loupe', 'Botón de lupa'),
          _t(
              'Amplia a tela para enxergar melhor. Use + e − para ajustar e as setas nas bordas para mover; toque no X para voltar a controlar.',
              'Enlarges the screen. Use + and − to adjust and the edge arrows to move; tap X to go back to control.',
              '放大屏幕以看得更清楚。用 + 和 − 调整，用边缘箭头移动；点击 X 返回控制。',
              'Agrandit l\'écran. Utilisez + et − pour ajuster et les flèches des bords pour déplacer ; touchez X pour revenir au contrôle.',
              'Amplía la pantalla. Usa + y − para ajustar y las flechas de los bordes para mover; toca X para volver a controlar.'),
        ),
        (
          _t('Botão do teclado', 'Keyboard button', '键盘按钮', 'Bouton clavier', 'Botón de teclado'),
          _t('Abre o teclado com as teclas especiais (Ctrl, Alt, setas...).',
              'Opens the keyboard with special keys (Ctrl, Alt, arrows...).',
              '打开带特殊键（Ctrl、Alt、方向键…）的键盘。',
              'Ouvre le clavier avec les touches spéciales (Ctrl, Alt, flèches...).',
              'Abre el teclado con teclas especiales (Ctrl, Alt, flechas...).'),
        ),
      ];

  // Wake-on-LAN (ajuda)
  String get wolTitle => _t('Ligar o PC à distância', 'Turn on the PC remotely', '远程开机',
      'Allumer le PC à distance', 'Encender el PC a distancia');
  String get wolHowTitle =>
      _t('Como funciona', 'How it works', '工作原理', 'Comment ça marche', 'Cómo funciona');
  String get wolHowBody => _t(
      'Um computador desligado não consegue receber comandos sozinho. Mas, se você tem outro computador seu ligado na mesma casa (na mesma internet), o RemoteOne usa esse que está ligado para "acordar" o que está desligado.\n\nResumindo: se você tem dois ou mais computadores na mesma rede e pelo menos um está ligado, o botão "Ligar" acende os outros — sem você precisar configurar nada.',
      'A computer that is off cannot receive commands on its own. But if you have another computer of yours turned on in the same house (same network), RemoteOne uses that one to "wake" the one that is off.\n\nIn short: if you have two or more computers on the same network and at least one is on, the "Turn on" button wakes the others — with no setup.',
      '关机的电脑无法自行接收命令。但如果你在同一处（同一网络）还有另一台开着的电脑，RemoteOne 会用它来"唤醒"已关机的那台。\n\n简单说：只要同一网络里有两台以上电脑，且至少一台开着，"开机"按钮就能唤醒其他电脑——无需任何配置。',
      "Un ordinateur éteint ne peut pas recevoir de commandes seul. Mais si vous avez un autre de vos ordinateurs allumé dans la même maison (même réseau), RemoteOne l'utilise pour « réveiller » celui qui est éteint.\n\nEn bref : si vous avez deux ordinateurs ou plus sur le même réseau et qu'au moins un est allumé, le bouton « Allumer » réveille les autres — sans aucune configuration.",
      'Un equipo apagado no puede recibir comandos por sí solo. Pero si tienes otro equipo tuyo encendido en la misma casa (misma red), RemoteOne usa ese para "despertar" al que está apagado.\n\nEn resumen: si tienes dos o más equipos en la misma red y al menos uno encendido, el botón "Encender" despierta a los demás — sin configurar nada.');
  String get wolNote => _t(
      'Se todos os seus computadores dessa casa estiverem desligados ao mesmo tempo, não dá para ligar nenhum à distância. É preciso deixar pelo menos um ligado.',
      'If all your computers on that network are off at the same time, none can be turned on remotely. Keep at least one on.',
      '如果那处的所有电脑同时关机，就无法远程开机。请至少保持一台开着。',
      "Si tous vos ordinateurs de cette maison sont éteints en même temps, aucun ne peut être allumé à distance. Gardez-en au moins un allumé.",
      'Si todos tus equipos de esa casa están apagados a la vez, no se puede encender ninguno a distancia. Deja al menos uno encendido.');
  String get wolPrepareTitle => _t('Preparar o computador', 'Prepare the computer', '准备电脑',
      "Préparer l'ordinateur", 'Preparar el equipo');
  String get wolPrepareBody => _t(
      'Para um computador poder ser aceso à distância, esse recurso precisa estar ativado nele. Em geral:\n\n•  Ligue a opção "Wake on LAN" (ligar pela rede) nas configurações do computador. Ela costuma ficar numa tela de configurações que aparece logo quando o PC liga. Se não achar, pesquise na internet "ativar Wake on LAN" com o modelo do seu computador.\n\n•  Se puder, conecte o computador por cabo de rede — por Wi-Fi esse recurso costuma não funcionar.\n\n•  Desligue o computador normalmente, mas deixe-o na tomada.',
      'For a computer to be turned on remotely, this feature must be enabled on it. Usually:\n\n•  Turn on the "Wake on LAN" option in the computer settings. It is often on a settings screen that appears right when the PC turns on. If you cannot find it, search online for "enable Wake on LAN" with your computer model.\n\n•  If possible, connect the computer with a network cable — over Wi-Fi this feature often does not work.\n\n•  Turn the computer off normally, but keep it plugged in.',
      '要让电脑能被远程开机，需要先在它上面启用该功能。通常：\n\n•  在电脑设置中启用"Wake on LAN"（网络唤醒）。它通常在开机时出现的设置界面里。如果找不到，可在网上搜索"启用 Wake on LAN"加上你的电脑型号。\n\n•  如果可以，请用网线连接电脑——通过 Wi-Fi 该功能通常无效。\n\n•  正常关机，但保持通电。',
      "Pour qu'un ordinateur puisse être allumé à distance, cette fonction doit y être activée. En général :\n\n•  Activez l'option « Wake on LAN » dans les paramètres de l'ordinateur. Elle se trouve souvent sur un écran de configuration qui apparaît au démarrage du PC. Si vous ne la trouvez pas, cherchez en ligne « activer Wake on LAN » avec le modèle de votre ordinateur.\n\n•  Si possible, connectez l'ordinateur par câble réseau — en Wi-Fi cette fonction ne marche souvent pas.\n\n•  Éteignez l'ordinateur normalement, mais laissez-le branché.",
      'Para que un equipo pueda encenderse a distancia, esta función debe estar activada en él. En general:\n\n•  Activa la opción "Wake on LAN" (encender por red) en la configuración del equipo. Suele estar en una pantalla de configuración que aparece al encender el PC. Si no la encuentras, busca en internet "activar Wake on LAN" con el modelo de tu equipo.\n\n•  Si puedes, conecta el equipo por cable de red — por Wi-Fi esta función suele no funcionar.\n\n•  Apaga el equipo normalmente, pero déjalo enchufado.');
  String get wolRouterTitle => _t('Ligar de fora de casa (avançado)',
      'Turn on from outside home (advanced)', '在外网开机（高级）',
      "Allumer hors du domicile (avancé)", 'Encender fuera de casa (avanzado)');
  String get wolRouterWarning => _t(
      'Atenção: este modo "abre uma porta" no seu roteador para a internet. Isso deixa a sua rede um pouco mais exposta a riscos de segurança. Use só se tiver experiência. O modo normal (acima) é seguro e não mexe em nada da sua rede.',
      'Warning: this mode "opens a door" on your router to the internet. That makes your network a bit more exposed to security risks. Use only if you have experience. The normal mode (above) is safe and does not touch your network.',
      '注意：此模式会在你的路由器上向互联网"开一个端口"，会让你的网络更容易受到安全风险。仅在你有经验时使用。上面的普通模式是安全的，不会改动你的网络。',
      "Attention : ce mode « ouvre une porte » sur votre routeur vers Internet. Cela expose un peu plus votre réseau aux risques de sécurité. À utiliser seulement si vous avez de l'expérience. Le mode normal (ci-dessus) est sûr et ne touche à rien de votre réseau.",
      'Atención: este modo "abre una puerta" en tu router hacia internet. Eso deja tu red un poco más expuesta a riesgos de seguridad. Úsalo solo si tienes experiencia. El modo normal (arriba) es seguro y no toca nada de tu red.');
  String get wolRouterBody => _t(
      'O modo normal só funciona quando você e o computador ligado estão na mesma rede. Este modo avançado permite acender o PC mesmo estando longe de casa — mas depende do seu roteador e da sua operadora (algumas não permitem conexões de fora).',
      'The normal mode only works when you and the computer that is on are on the same network. This advanced mode lets you turn on the PC even when away from home — but it depends on your router and your internet provider (some do not allow connections from outside).',
      '普通模式只在你和开着的电脑处于同一网络时有效。此高级模式让你即使不在家也能开机——但取决于你的路由器和运营商（有些不允许外部连接）。',
      "Le mode normal ne fonctionne que lorsque vous et l'ordinateur allumé êtes sur le même réseau. Ce mode avancé permet d'allumer le PC même loin de chez vous — mais cela dépend de votre routeur et de votre opérateur (certains n'autorisent pas les connexions de l'extérieur).",
      'El modo normal solo funciona cuando tú y el equipo encendido están en la misma red. Este modo avanzado permite encender el PC incluso lejos de casa — pero depende de tu router y de tu operador (algunos no permiten conexiones desde fuera).');
  String get wolRouterIdeaTitle =>
      _t('Ideia geral', 'General idea', '总体思路', 'Idée générale', 'Idea general');
  String get wolRouterIdea => _t(
      '•  Nas configurações do roteador, cria-se uma regra que deixa o "sinal para ligar" chegar da internet até o computador em casa.\n•  Alguns roteadores já têm um botão pronto chamado "Wake on LAN".\n•  Se você não tem familiaridade com configurações de roteador, o mais seguro é ficar no modo normal (deixar um computador ligado em casa).',
      '•  In the router settings, you create a rule that lets the "turn-on signal" reach the computer at home from the internet.\n•  Some routers already have a ready button called "Wake on LAN".\n•  If you are not familiar with router settings, the safest is to stay on the normal mode (keep a computer on at home).',
      '•  在路由器设置中创建一条规则，让"开机信号"能从互联网到达家里的电脑。\n•  有些路由器已内置"Wake on LAN"按钮。\n•  如果你不熟悉路由器设置，最安全的做法是使用普通模式（在家保持一台电脑开着）。',
      "•  Dans les paramètres du routeur, on crée une règle qui laisse le « signal d'allumage » atteindre l'ordinateur à la maison depuis Internet.\n•  Certains routeurs ont déjà un bouton « Wake on LAN ».\n•  Si vous n'êtes pas à l'aise avec les paramètres du routeur, le plus sûr est de rester en mode normal (garder un ordinateur allumé à la maison).",
      '•  En la configuración del router, se crea una regla que deja que la "señal de encendido" llegue desde internet al equipo de casa.\n•  Algunos routers ya tienen un botón llamado "Wake on LAN".\n•  Si no tienes familiaridad con la configuración del router, lo más seguro es quedarte en el modo normal (dejar un equipo encendido en casa).');
  String get wolRouterFuture => _t(
      'Este modo avançado ainda será integrado ao botão "Ligar" numa próxima atualização.',
      'This advanced mode will be integrated into the "Turn on" button in a future update.',
      '此高级模式将在未来更新中集成到"开机"按钮。',
      "Ce mode avancé sera intégré au bouton « Allumer » dans une future mise à jour.",
      'Este modo avanzado se integrará al botón "Encender" en una próxima actualización.');
}
