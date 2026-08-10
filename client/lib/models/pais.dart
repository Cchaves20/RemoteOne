/// Países no seletor de telefone, e a limpeza do número digitado.
///
/// **É uma cópia da tabela do servidor** (`backend/app/telefone.py`), e a
/// duplicação é deliberada: é esta lista que desenha o seletor, e buscá-la pela
/// rede antes de mostrar um formulário faria a tela de cadastro depender de uma
/// chamada HTTP para exibir um campo.
///
/// Quem **decide** continua sendo o servidor: o app pode estar velho, e o
/// número vai normalizado e é conferido de novo do outro lado. Se as duas
/// divergirem, o servidor recusa e o app mostra o motivo que veio de lá. Há um
/// endpoint (`GET /auth/countries`) para o dia em que valer a pena atualizar a
/// lista sem reinstalar o app.
class Pais {
  const Pais(this.iso, this.nome, this.ddi, this.minimo, this.maximo);

  final String iso;
  final String nome;

  /// Código de discagem, sem o `+`.
  final String ddi;

  /// Tamanho do número **nacional** — sem o código do país e sem o zero de
  /// tronco (o `0` que se disca antes do DDD dentro do Brasil).
  final int minimo;
  final int maximo;

  /// A bandeira como emoji, derivada do ISO em vez de guardada.
  ///
  /// Cada letra vira o indicador regional correspondente, e o par forma a
  /// bandeira. Guardar o emoji na tabela seria guardar o que já está no ISO.
  String get bandeira => String.fromCharCodes(
        iso.codeUnits.map((c) => 0x1F1E6 + c - 0x41),
      );

  @override
  bool operator ==(Object other) => other is Pais && other.iso == iso;

  @override
  int get hashCode => iso.hashCode;

  /// A lista, com o Brasil na frente por ser o mercado inicial.
  static const List<Pais> todos = [
    Pais('BR', 'Brasil', '55', 10, 11),
    Pais('PT', 'Portugal', '351', 9, 9),
    Pais('US', 'Estados Unidos', '1', 10, 10),
    Pais('CA', 'Canadá', '1', 10, 10),
    Pais('AR', 'Argentina', '54', 10, 11),
    Pais('CL', 'Chile', '56', 9, 9),
    Pais('CO', 'Colômbia', '57', 10, 10),
    Pais('MX', 'México', '52', 10, 10),
    Pais('PY', 'Paraguai', '595', 9, 9),
    Pais('PE', 'Peru', '51', 9, 9),
    Pais('UY', 'Uruguai', '598', 8, 9),
    Pais('BO', 'Bolívia', '591', 8, 8),
    Pais('ES', 'Espanha', '34', 9, 9),
    Pais('FR', 'França', '33', 9, 9),
    Pais('IT', 'Itália', '39', 9, 11),
    Pais('DE', 'Alemanha', '49', 10, 11),
    Pais('GB', 'Reino Unido', '44', 10, 10),
    Pais('IE', 'Irlanda', '353', 9, 9),
    Pais('NL', 'Países Baixos', '31', 9, 9),
    Pais('BE', 'Bélgica', '32', 9, 9),
    Pais('CH', 'Suíça', '41', 9, 9),
    Pais('AT', 'Áustria', '43', 10, 13),
    Pais('SE', 'Suécia', '46', 9, 9),
    Pais('NO', 'Noruega', '47', 8, 8),
    Pais('DK', 'Dinamarca', '45', 8, 8),
    Pais('FI', 'Finlândia', '358', 9, 10),
    Pais('PL', 'Polônia', '48', 9, 9),
    Pais('JP', 'Japão', '81', 10, 10),
    Pais('AU', 'Austrália', '61', 9, 9),
    Pais('NZ', 'Nova Zelândia', '64', 8, 10),
    Pais('ZA', 'África do Sul', '27', 9, 9),
    Pais('AO', 'Angola', '244', 9, 9),
    Pais('MZ', 'Moçambique', '258', 9, 9),
  ];

  static Pais? porIso(String iso) {
    for (final p in todos) {
      if (p.iso == iso.toUpperCase()) return p;
    }
    return null;
  }

  static const Pais padrao = Pais('BR', 'Brasil', '55', 10, 11);
}

/// Fica só com os algarismos.
///
/// Espaço, parêntese, hífen, ponto e o `+` são enfeite de leitura: quem digita
/// "(11) 98765-4321" quer o mesmo número de quem digita "11987654321", e
/// recusar um dos dois seria recusar por causa da pontuação.
String soDigitos(String bruto) =>
    bruto.replaceAll(RegExp(r'[^0-9]'), '');

/// O número em E.164 (`+5511987654321`), ou `null` se não parece um número.
///
/// A mesma função existe no servidor, e as duas fazem a mesma coisa pelo mesmo
/// motivo: sem normalizar, "(11) 98765-4321" e "11987654321" seriam duas
/// contas diferentes para a mesma pessoa.
String? normalizarTelefone(String bruto, Pais pais) {
  var digitos = soDigitos(bruto);
  if (digitos.isEmpty) return null;

  // O DDI já veio digitado: tira, mas só se o que sobra ainda couber. Sem essa
  // checagem, um número que por acaso começa com os mesmos dígitos do país
  // seria mutilado — o `55` do Brasil é o começo legítimo de um DDD 55.
  if (digitos.startsWith(pais.ddi)) {
    final resto = digitos.substring(pais.ddi.length);
    if (resto.length >= pais.minimo && resto.length <= pais.maximo) {
      digitos = resto;
    }
  }
  // O zero de tronco, pelo mesmo cuidado.
  if (digitos.startsWith('0')) {
    final resto = digitos.replaceFirst(RegExp(r'^0+'), '');
    if (resto.length >= pais.minimo && resto.length <= pais.maximo) {
      digitos = resto;
    }
  }

  if (digitos.length < pais.minimo || digitos.length > pais.maximo) return null;
  return '+${pais.ddi}$digitos';
}

/// `+5511987654321` → `+55 11 ••••• 4321`, para a tela de verificação dizer
/// para onde o código foi sem repor o número inteiro numa tela que pode estar
/// sendo vista por outra pessoa. Os quatro últimos bastam para reconhecer.
String mascararDestino(String destino) {
  if (destino.contains('@')) {
    final partes = destino.split('@');
    final nome = partes.first;
    final visivel = nome.length <= 2 ? nome : nome.substring(0, 2);
    return '$visivel${'•' * (nome.length - visivel.length)}@${partes.last}';
  }
  if (destino.length <= 4) return destino;
  final fim = destino.substring(destino.length - 4);
  return '${'•' * (destino.length - 4)}$fim';
}
