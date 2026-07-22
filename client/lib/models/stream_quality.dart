/// Presets de qualidade/desempenho da transmissão de tela.
///
/// Cada preset combina fps, qualidade do JPEG e largura máxima. "Econômico"
/// prioriza fluidez em redes fracas; "Nítido" prioriza detalhe. O backend
/// ainda limita os valores à faixa que aceita.
enum StreamQuality {
  economico(label: 'Econômico', fps: 5, quality: 35, maxWidth: 960),
  equilibrado(label: 'Equilibrado', fps: 10, quality: 55, maxWidth: 1280),
  nitido(label: 'Nítido', fps: 15, quality: 75, maxWidth: 1600);

  const StreamQuality({
    required this.label,
    required this.fps,
    required this.quality,
    required this.maxWidth,
  });

  final String label;
  final int fps;
  final int quality;
  final int maxWidth;

  static StreamQuality fromName(String? name) {
    return StreamQuality.values.firstWhere(
      (q) => q.name == name,
      orElse: () => StreamQuality.equilibrado,
    );
  }
}
