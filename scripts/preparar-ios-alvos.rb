# Põe o código nativo do Deskside no projeto iOS gerado pelo `flutter create`.
#
# Chamado por `preparar-ios.sh`, a partir de `client/`. Separado em Ruby
# porque quem sabe editar o projeto do Xcode sem corrompê-lo é a gema
# `xcodeproj` (a mesma do CocoaPods), e porque assim dá para testar este
# arquivo contra um projeto falso fora do Mac.
#
# O que ele faz, e pode rodar duas vezes sem duplicar nada:
#
# 1. **Alvo Runner (o app):** copia `nativo/ios/Comum/*.swift` e
#    `nativo/ios/Runner/*.swift` e os põe na compilação. É onde moram as ações
#    da Siri e do app Atalhos.
# 2. **Alvo DesksideWidget (o widget):** cria a extensão de widget, com o
#    código de `nativo/ios/DesksideWidget/` mais o código comum, e a embute no
#    app. O widget só existe no iOS 17 ou mais novo, que é onde os botões
#    funcionam sem abrir o app.
# 3. **Idioma de desenvolvimento em pt-BR:** é ele que diz à Siri em que
#    língua estão as frases de `DesksideAtalhos.swift`.

require 'fileutils'
require 'xcodeproj'

WIDGET = 'DesksideWidget'
BUNDLE_DO_APP = 'com.deskside.desksideClient'
BUNDLE_DO_WIDGET = "#{BUNDLE_DO_APP}.#{WIDGET}"

def falhar(motivo)
  abort("FALHOU: #{motivo}")
end

projeto = Xcodeproj::Project.open('ios/Runner.xcodeproj')
runner = projeto.targets.find { |t| t.name == 'Runner' } or falhar('sem o alvo Runner')
grupo_runner = projeto.main_group['Runner'] or falhar('sem o grupo Runner')

# Um arquivo copiado para `pasta`, referenciado no `grupo` e compilado nos
# `alvos`. Devolve a referência.
def incluir(origem, pasta, grupo, alvos)
  nome = File.basename(origem)
  FileUtils.mkdir_p(pasta)
  FileUtils.cp(origem, File.join(pasta, nome))
  ref = grupo.files.find { |f| f.path == nome } || grupo.new_reference(nome)
  alvos.each do |alvo|
    next if alvo.source_build_phase.files_references.include?(ref)

    alvo.add_file_references([ref])
  end
  ref
end

# --- 1. O app ---------------------------------------------------------------

comuns = Dir.glob('nativo/ios/Comum/*.swift').sort
do_app = Dir.glob('nativo/ios/Runner/*.swift').sort
falhar('nenhum .swift em client/nativo/ios') if comuns.empty? || do_app.empty?

refs_comuns = comuns.map { |f| incluir(f, 'ios/Runner', grupo_runner, [runner]) }
do_app.each { |f| incluir(f, 'ios/Runner', grupo_runner, [runner]) }
puts "Swift no Runner: #{(comuns + do_app).map { |f| File.basename(f) }.join(', ')}"

# --- 2. O widget --------------------------------------------------------------

widget = projeto.targets.find { |t| t.name == WIDGET }
unless widget
  widget = projeto.new_target(:app_extension, WIDGET, :ios, '17.0', nil, :swift)
  puts "alvo #{WIDGET} criado"
end

grupo_widget = projeto.main_group[WIDGET] || projeto.main_group.new_group(WIDGET, WIDGET)
Dir.glob("nativo/ios/#{WIDGET}/*.swift").sort.each do |f|
  incluir(f, "ios/#{WIDGET}", grupo_widget, [widget])
end
%w[Info.plist DesksideWidget.entitlements].each do |nome|
  origem = "nativo/ios/#{WIDGET}/#{nome}"
  falhar("falta #{origem}") unless File.exist?(origem)
  FileUtils.cp(origem, "ios/#{WIDGET}/#{nome}")
  grupo_widget.new_reference(nome) unless grupo_widget.files.any? { |f| f.path == nome }
end
# O código comum (acesso ao servidor e as ações) também entra no widget.
refs_comuns.each do |ref|
  widget.add_file_references([ref]) unless widget.source_build_phase.files_references.include?(ref)
end

# As configurações do widget herdam as do Runner com o mesmo nome. É de lá
# (`Flutter/Release.xcconfig` e companhia) que vêm FLUTTER_BUILD_NAME e
# FLUTTER_BUILD_NUMBER, que o Info.plist do widget usa para ter a mesma versão
# do app — a App Store recusa extensão com versão diferente.
base_por_nome = runner.build_configurations.to_h { |c| [c.name, c.base_configuration_reference] }
widget.build_configurations.each do |config|
  config.base_configuration_reference = base_por_nome[config.name] if base_por_nome[config.name]
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_DO_WIDGET,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'INFOPLIST_FILE' => "#{WIDGET}/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => "#{WIDGET}/DesksideWidget.entitlements",
    'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => [
      '$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'
    ],
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => '',
    'ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME' => ''
  )
end

# O app depende do widget e o leva dentro (pasta PlugIns).
runner.add_dependency(widget) unless runner.dependencies.any? { |d| d.target == widget }
embutir = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless embutir
  embutir = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embutir.symbol_dst_subfolder_spec = :plug_ins
end
unless embutir.files_references.include?(widget.product_reference)
  arquivo = embutir.add_file_reference(widget.product_reference)
  arquivo.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
# **Antes** do "Thin Binary" do Flutter. Com a cópia depois dele, o Xcode
# acusa "Cycle inside Runner" — o erro mais conhecido de quem põe widget num
# app Flutter, e que não diz o que fazer.
fino = runner.build_phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if fino && runner.build_phases.index(embutir) > fino
  runner.build_phases.delete(embutir)
  runner.build_phases.insert(fino, embutir)
end

# --- 3. Idioma ----------------------------------------------------------------

raiz = projeto.root_object
raiz.development_region = 'pt-BR'
raiz.known_regions << 'pt-BR' unless raiz.known_regions.include?('pt-BR')

projeto.save
puts "alvo #{WIDGET} pronto (#{BUNDLE_DO_WIDGET}), embutido no Runner"
