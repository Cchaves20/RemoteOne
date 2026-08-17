import '../l10n/strings.dart';

/// Transforma o corpo de erro do servidor numa frase que se lê.
///
/// Existe por causa de uma tela real: ao adicionar um passo de automação, o app
/// mostrou isto, palavra por palavra, dentro de um aviso vermelho:
///
/// ```text
/// [{type: literal_error, loc: [body, steps, 0, kind], msg: Input should be
/// 'launch', 'close', ..., input: close_all, ctx: {expected: ...}}]
/// ```
///
/// Era o `detail` de um 422 do FastAPI — uma **lista de objetos** — passando por
/// `toString()`. Duas coisas erradas ao mesmo tempo: ninguém entende, e o que
/// realmente havia acontecido (o servidor estava desatualizado e não conhecia o
/// passo novo) ficou escondido no meio do despejo.
///
/// ## Onde a tradução mora, e por quê
///
/// Aqui, no app, e não no servidor: é o app que sabe em que idioma a pessoa
/// está. Um texto amigável montado no backend sairia num idioma só.
///
/// A exceção conhecida são os erros dos nossos próprios validadores
/// (`value_error`): a frase deles é escrita no backend, em português, e passa
/// direto. É melhor que a alternativa — "dados inválidos" apagaria justamente a
/// explicação ("agendamento precisa de um computador escolhido") que resolve o
/// problema. Localizá-los de verdade pede um código de erro por validador, e
/// isso ainda não existe.
String traduzirErro(int status, Object? detail, Strings t) {
  // `detail` texto é o caso comum e já é uma frase: os erros que este servidor
  // levanta de propósito (`HTTPException`) vêm assim.
  if (detail is String && detail.trim().isNotEmpty) {
    return detail;
  }
  if (detail is List && detail.isNotEmpty) {
    final frases = <String>[];
    for (final item in detail) {
      if (item is Map) {
        frases.add(_umErro(item, t));
      }
    }
    if (frases.isNotEmpty) {
      // Uma frase por problema, e todas: o formulário de cadastro pode ter dois
      // campos errados, e mostrar só o primeiro faria a pessoa corrigir, tentar
      // de novo e receber o segundo — parecendo que o app inventa exigências.
      return frases.join('\n');
    }
  }
  return t.erroGenerico(status);
}

String _umErro(Map item, Strings t) {
  final tipo = (item['type'] ?? '').toString();
  final campo = _campo(item['loc'], t);
  final msg = (item['msg'] ?? '').toString();

  // Erro dos nossos validadores: a frase já é humana e explica o caso. O
  // Pydantic prefixa com "Value error, " — que não interessa a ninguém.
  if (tipo == 'value_error' || tipo == 'assertion_error') {
    final limpa = msg.replaceFirst(RegExp(r'^(Value|Assertion) error,\s*'), '');
    return limpa.isEmpty ? t.erroCampoInvalido(campo) : limpa;
  }

  switch (tipo) {
    case 'missing':
      return t.erroCampoFaltando(campo);
    // Um valor fora da lista fechada quase nunca é erro de quem digitou: as
    // listas fechadas deste servidor (tipo de passo, ação de energia) são
    // preenchidas pelo próprio app. Quando o app manda um valor que o servidor
    // não conhece, o servidor é mais velho que o app — e é isso que a pessoa
    // precisa ler, em vez de "valor inválido".
    case 'literal_error':
    case 'enum':
      return t.erroServidorAntigo(campo);
    case 'string_too_short':
    case 'too_short':
      return t.erroCampoCurto(campo);
    case 'string_too_long':
    case 'too_long':
      return t.erroCampoLongo(campo);
    case 'greater_than':
    case 'greater_than_equal':
    case 'less_than':
    case 'less_than_equal':
      return t.erroCampoForaDoIntervalo(campo);
    default:
      // Tipo que não conhecemos ainda. O nome do campo é a parte que ajuda, e
      // a mensagem do servidor vai junto entre parênteses: ela é em inglês e
      // técnica, mas é a única pista que resta — e escondê-la deixaria a
      // investigação sem nada.
      return msg.isEmpty
          ? t.erroCampoInvalido(campo)
          : '${t.erroCampoInvalido(campo)} ($msg)';
  }
}

/// O nome do campo, a partir do `loc` do Pydantic.
///
/// `["body", "steps", 0, "kind"]` → "kind", e não "body" nem "0": o primeiro é
/// sempre "body" (a pessoa não precisa saber que existe um corpo de requisição)
/// e os números são posições em lista.
String _campo(Object? loc, Strings t) {
  if (loc is! List) return t.erroCampoSemNome;
  for (final parte in loc.reversed) {
    if (parte is String && parte != 'body') {
      return _rotulos[parte] ?? parte;
    }
  }
  return t.erroCampoSemNome;
}

/// Nome bonito para os campos que a pessoa vê na tela.
///
/// Só os que aparecem em formulário. Os outros passam com o nome técnico de
/// propósito: `steps[0].kind` não tem tradução útil, e inventar uma esconderia
/// de qual passo se fala.
///
/// **Não localizado**, e isto é uma escolha: são nomes de campo, iguais aos
/// rótulos que as telas já usam nos cinco idiomas. Traduzi-los aqui criaria uma
/// segunda lista para manter em sincronia com a primeira.
const Map<String, String> _rotulos = {
  'email': 'e-mail',
  'phone': 'telefone',
  'password': 'senha',
  'password_confirm': 'confirmação da senha',
  'first_name': 'nome',
  'last_name': 'sobrenome',
  'birth_date': 'data de nascimento',
  'code': 'código',
  'name': 'nome',
  'schedule_time': 'horário',
  'schedule_days': 'dias da semana',
  'device_id': 'computador',
};
