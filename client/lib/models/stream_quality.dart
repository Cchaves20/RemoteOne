/// O que o app pede ao computador na transmissão de tela.
///
/// Antes eram três presets nas Configurações (Econômico, Equilibrado,
/// Nítido). Com o vídeo (H.264) ligado, o agente usa o próprio teto de
/// largura e de quadros (`video_max_width`, `video_fps` em
/// `agent/src/client.rs`), e na tela os três ficavam iguais. Os valores só
/// pesam no modo antigo, por imagens (JPEG), e são os do antigo
/// "Equilibrado", que era o padrão. O backend ainda limita à faixa que aceita.
abstract final class QualidadeDaTela {
  static const fps = 10;
  static const quality = 55;
  static const maxWidth = 1280;
}
