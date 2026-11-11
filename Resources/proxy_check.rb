require 'json'
require 'yaml'
require 'open3'
require 'uri'
require 'ipaddr'

class CheckFailed < StandardError
  attr_reader :ip, :country
  def initialize(message, ip: nil, country: nil)
    super(message)
    @ip, @country = ip, country
  end
end

DOMAINS = %w[claude.ai claude.com claude.app claudeusercontent.com claudemcpcontent.com anthropic.com anthropic.services].freeze
GROUP = 'Claude专用'.freeze
NODE = '供应商-HTTP'.freeze

def verify_state(system_proxy, state, rules, proxies)
  port = state['mixed-port'].to_i
  raise CheckFailed, 'Clash 没有提供有效的本地代理端口。' unless port.between?(1, 65_535)
  %w[HTTP HTTPS].each do |kind|
    enabled = system_proxy[kind + 'Enable'] == '1'
    local = %w[127.0.0.1 localhost ::1].include?(system_proxy[kind + 'Proxy'])
    correct_port = system_proxy[kind + 'Port'].to_i == port
    raise CheckFailed, '系统代理尚未指向 Clash。请先打开 Clash Verge 并开启“系统代理”。' unless enabled && local && correct_port
  end
  raise CheckFailed, '系统启用了自动代理配置，暂时无法确认 Claude 的出口。' if system_proxy['ProxyAutoConfigEnable'] == '1' || system_proxy['ProxyAutoDiscoveryEnable'] == '1'
  raise CheckFailed, 'Clash 当前不是“规则”模式，请切换为规则模式。' unless state['mode'] == 'rule'
  prefix = rules.take_while { |rule| rule['type'] != 'Match' }
  # shortcut: checks the domain-only profile installed here; review the checker if its rule structure changes.
  valid_structure = prefix.all? { |rule| rule['type'] == 'DomainSuffix' && rule['proxy'] == GROUP }
  covered = prefix.map { |rule| rule['payload'] }
  raise CheckFailed, 'Claude 的分流规则不完整或已经改变，请选中“Claude 桌面 App · 美国出口”配置。' unless valid_structure && (DOMAINS - covered).empty?
  raise CheckFailed, 'Claude 专用分组没有选中已验证的供应商节点。' unless proxies.dig(GROUP, 'now') == NODE
end

def verify_country(info)
  begin
    ip = IPAddr.new(info.fetch('ip')).to_s
  rescue IPAddr::InvalidAddressError, KeyError, TypeError
    raise CheckFailed, '未能取得有效的出口 IP，禁止启动 Claude。'
  end
  country = info['country'].is_a?(String) && info['country'].match?(/\A[A-Z]{2}\z/) ? info['country'] : nil
  unless country == 'US'
    message = country ? "出口国家为 #{country}，不是美国，禁止启动 Claude。" : '无法确认出口国家，禁止启动 Claude。'
    raise CheckFailed.new(message, ip: ip, country: country)
  end
  { ip: ip, country: country }
end

def read_yaml(path)
  value = YAML.safe_load(File.read(path), [], [], true)
  raise CheckFailed, '无法读取 Clash 配置，请先打开 Clash Verge。' unless value.is_a?(Hash)
  value
end

def curl_json(arguments, config = '')
  output, _error, status = Open3.capture3('/usr/bin/curl', '-q', '--silent', '--fail', *arguments, stdin_data: config)
  raise CheckFailed, '代理检测请求未成功，暂时无法确认网络出口。' unless status.success?
  JSON.parse(output)
end

def check_proxy(quick: false)
  root = File.expand_path('~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev')
  base = read_yaml(File.join(root, 'config.yaml'))
  runtime = read_yaml(File.join(root, 'clash-verge.yaml'))
  socket = runtime['external-controller-unix'] || base['external-controller-unix']
  raise CheckFailed, 'Clash Verge 或代理内核尚未运行，请先打开 Clash Verge。' unless socket.is_a?(String) && File.socket?(socket)
  secret = runtime['secret'] || base['secret']
  headers = secret.to_s.empty? ? '' : "header = #{JSON.generate('Authorization: Bearer ' + secret.to_s)}\n"
  api = lambda do |path, timeout = 4|
    curl_json(['--noproxy', '*', '--unix-socket', socket, '--connect-timeout', '2', '--max-time', timeout.to_s, '--config', '-', 'http://localhost' + path], headers)
  end
  text, _error, status = Open3.capture3('/usr/sbin/scutil', '--proxy')
  raise CheckFailed, '无法读取系统代理状态，请手动确认 Clash Verge。' unless status.success?
  system_proxy = text.lines.each_with_object({}) do |line, result|
    match = line.match(/^\s*(\w+)\s*:\s*(.*?)\s*$/)
    result[match[1]] = match[2] if match
  end
  state = api.call('/configs')
  verify_state(system_proxy, state, api.call('/rules').fetch('rules'), api.call('/proxies').fetch('proxies'))
  query = URI.encode_www_form('url' => 'https://api.anthropic.com/', 'timeout' => '6000')
  encoded_node = URI.encode_www_form_component(NODE).gsub('+', '%20')
  health = api.call('/proxies/' + encoded_node + '/delay?' + query, 8)
  raise CheckFailed, '美国节点目前无法通过 Anthropic 连通性检测，请检查节点。' unless health['delay'].to_i > 0
  return { ok: true, message: '系统代理、Claude 分流和 Anthropic 连通性检查通过。' } if quick
  port = state.fetch('mixed-port').to_i
  info = curl_json(['--proxy', "http://127.0.0.1:#{port}", '--noproxy', '', '--connect-timeout', '3', '--max-time', '8', 'https://ipinfo.io/json'])
  verified = verify_country(info)
  { ok: true, message: '美国出口已核验，可以启动 Claude。' }.merge(verified)
end

def self_test
  system_proxy = %w[HTTP HTTPS].each_with_object({}) do |kind, result|
    result.merge!(kind + 'Enable' => '1', kind + 'Proxy' => '127.0.0.1', kind + 'Port' => '7897')
  end
  state = { 'mixed-port' => 7897, 'mode' => 'rule' }
  rules = DOMAINS.map { |domain| { 'type' => 'DomainSuffix', 'payload' => domain, 'proxy' => GROUP } } + [{ 'type' => 'Match', 'proxy' => 'DIRECT' }]
  proxies = { GROUP => { 'now' => NODE } }
  verify_state(system_proxy, state, rules, proxies)
  verified = verify_country('ip' => '192.0.2.10', 'country' => 'US')
  raise 'Exit IP was lost' unless verified == { ip: '192.0.2.10', country: 'US' }
  failures = [
    -> { verify_state(system_proxy.merge('HTTPEnable' => '0'), state, rules, proxies) },
    -> { verify_state(system_proxy.merge('HTTPSPort' => '8888'), state, rules, proxies) },
    -> { verify_state(system_proxy, state.merge('mode' => 'direct'), rules, proxies) },
    -> { verify_state(system_proxy, state, rules.drop(1), proxies) },
    -> { verify_state(system_proxy, state, [{ 'type' => 'Match', 'proxy' => 'DIRECT' }] + rules, proxies) },
    -> { verify_state(system_proxy, state, rules, { GROUP => { 'now' => 'DIRECT' } }) },
    -> { verify_country('ip' => '192.0.2.20', 'country' => 'CN') },
    -> { verify_country('ip' => '192.0.2.20') },
    -> { verify_country('ip' => 'invalid', 'country' => 'US') },
    -> { verify_country({}) }
  ]
  failures.each do |failure|
    begin
      failure.call
    rescue CheckFailed
      next
    end
    raise 'A failed check was incorrectly accepted'
  end
  begin
    verify_country('ip' => '192.0.2.20', 'country' => 'CN')
  rescue CheckFailed => error
    raise 'Non-US exit IP was lost' unless error.ip == '192.0.2.20' && error.country == 'CN'
  end
  { ok: true, message: "自检通过：正常状态及 #{failures.length} 种异常状态均符合预期，出口 IP 会保留供面板显示。" }
end

begin
  result = ARGV.include?('--self-test') ? self_test : check_proxy(quick: ARGV.include?('--quick'))
rescue CheckFailed => error
  result = { ok: false, message: error.message, ip: error.ip, country: error.country }
rescue StandardError
  result = { ok: false, message: '检测未能完成，暂时无法确认美国出口。请手动检查 Clash Verge。' }
end
puts JSON.generate(result)
