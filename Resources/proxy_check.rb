require 'json'
require 'yaml'
require 'open3'
require 'uri'
require 'ipaddr'

class CheckFailed < StandardError
  attr_reader :ip, :country, :kind, :code
  def initialize(message, ip: nil, country: nil, kind: 'configuration', code: 'configuration')
    super(message)
    @ip, @country = ip, country
    @kind, @code = kind, code
  end
end

DOMAINS = %w[claude.ai claude.com claude.app claudeusercontent.com claudemcpcontent.com anthropic.com anthropic.services].freeze
CONFIG_PATH = File.expand_path('~/.config/claude-proxy-guard/config.json').freeze
EXIT_PROBES = [
  [:json, 'https://ipinfo.io/json'],
  [:json, 'https://ipinfo.io/json'],
  [:trace, 'https://claude.ai/cdn-cgi/trace'],
  [:trace, 'https://api.anthropic.com/cdn-cgi/trace']
].freeze

def load_settings(path = CONFIG_PATH, env = ENV)
  saved = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  saved = {} unless saved.is_a?(Hash)
  pick = lambda do |env_key, key, fallback|
    raw = env[env_key].to_s.strip
    raw = saved[key].to_s.strip if raw.empty?
    raw.empty? ? fallback : raw
  end
  country = pick.call('CLAUDE_GUARD_COUNTRY', 'country', 'US').upcase
  raise CheckFailed, "目标出口国家代码无效（#{country}），请填写两位大写 ISO 国家码（如 US）。" unless country.match?(/\A[A-Z]{2}\z/)
  {
    group: pick.call('CLAUDE_GUARD_GROUP', 'group', 'Claude专用'),
    node: pick.call('CLAUDE_GUARD_NODE', 'node', '供应商-HTTP'),
    country: country
  }
rescue JSON::ParserError
  raise CheckFailed, '本地守卫配置文件格式错误，请检查 ~/.config/claude-proxy-guard/config.json。'
end

def verify_state(system_proxy, state, rules, proxies, group: 'Claude专用', node: '供应商-HTTP')
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
  # ponytail: enforces dedicated top-of-file DomainSuffix routing; relax if multi-rule profile support is needed.
  valid_structure = prefix.all? { |rule| rule['type'] == 'DomainSuffix' && rule['proxy'] == group }
  covered = prefix.map { |rule| rule['payload'] }
  raise CheckFailed, "Claude 的分流规则不完整或未全部指向“#{group}”分组，请检查 Clash 配置。" unless valid_structure && (DOMAINS - covered).empty?
  raise CheckFailed, "代理分组“#{group}”当前未选中锁定节点“#{node}”。" unless proxies.dig(group, 'now') == node
end

def claude_domain?(host)
  normalized = host.to_s.strip.downcase.chomp('.')
  return false if normalized.empty?
  DOMAINS.any? { |domain| normalized == domain || normalized.end_with?(".#{domain}") }
end

def verify_connections(connections, group: 'Claude专用', node: '供应商-HTTP')
  Array(connections).each do |conn|
    next unless conn.is_a?(Hash)
    meta = conn['metadata'].is_a?(Hash) ? conn['metadata'] : {}
    matched = [meta['host'], meta['sniffHost']].find { |host| claude_domain?(host) }
    next unless matched
    chains = conn['chains']
    next if chains.is_a?(Array) && chains.first == node && chains.include?(group)
    actual = chains.is_a?(Array) && !chains.empty? ? chains.join(' ← ') : '未知链路'
    raise CheckFailed.new("检测到 #{matched.to_s.chomp('.')} 活跃连接未走锁定节点（实际链路：#{actual}），已触发防漏保护。", kind: 'leak', code: 'route_leak')
  end
end

def verify_country(info, expected_country = 'US')
  begin
    ip = IPAddr.new(info.fetch('ip')).to_s
  rescue IPAddr::InvalidAddressError, KeyError, TypeError
    raise CheckFailed.new('出口查询未返回有效 IP，暂时无法确认出口。', kind: 'transient', code: 'invalid_ip')
  end
  country = info['country'].is_a?(String) && info['country'].match?(/\A[A-Z]{2}\z/) ? info['country'] : nil
  unless country == expected_country
    target_name = expected_country == 'US' ? '美国 (US)' : expected_country
    message = country ? "出口国家为 #{country}，不是 #{target_name}，禁止启动 Claude。" : '无法确认出口国家，禁止启动 Claude。'
    raise CheckFailed.new(message, ip: ip, country: country, kind: country ? 'country' : 'transient', code: country ? 'country_mismatch' : 'country_unknown')
  end
  { ip: ip, country: country, expectedCountry: expected_country }
end

def read_yaml(path)
  value = YAML.safe_load(File.read(path), [], [], true)
  raise CheckFailed, '无法读取 Clash 配置，请先打开 Clash Verge。' unless value.is_a?(Hash)
  value
end

def curl_raw(arguments, config = '')
  output, _error, status = Open3.capture3('/usr/bin/curl', '-q', '--silent', '--fail', '--write-out', "\n%{http_code}", *arguments, stdin_data: config)
  [output, status.exitstatus]
end

def curl_json(arguments, config = '', label: '代理检测', kind: 'transient')
  output, exit_code = curl_raw(arguments, config)
  parse_curl_result(output, exit_code, label, kind)
end

def curl_trace(arguments, label: '出口 IP 查询', kind: 'transient')
  output, exit_code = curl_raw(arguments)
  parse_trace_result(output, exit_code, label, kind)
end

def parse_http_body(output, exit_code, label, kind = 'transient')
  body, _, http_status = output.rpartition("\n")
  return body if exit_code == 0
  code = exit_code == 28 ? 'timeout' : (http_status.to_i > 0 ? "http_#{http_status}" : "curl_#{exit_code}")
  detail = http_status == '429' ? '被限流（HTTP 429）' : (exit_code == 28 ? '超时' : "未成功（#{code}）")
  raise CheckFailed.new(label + detail + '，暂时无法确认检测结果。', kind: kind, code: code)
end

def parse_curl_result(output, exit_code, label, kind = 'transient')
  JSON.parse(parse_http_body(output, exit_code, label, kind))
rescue JSON::ParserError
  raise CheckFailed.new(label + '返回了无法解析的结果。', kind: kind, code: 'invalid_json')
end

def parse_trace_result(output, exit_code, label = '出口 IP 查询', kind = 'transient')
  body = parse_http_body(output, exit_code, label, kind)
  pairs = body.each_line.each_with_object({}) do |line, result|
    key, value = line.strip.split('=', 2)
    result[key] = value if key && value && !key.empty?
  end
  raise CheckFailed.new(label + '返回了无法解析的结果。', kind: kind, code: 'invalid_trace') unless pairs.key?('ip')
  loc = pairs['loc']
  { 'ip' => pairs['ip'], 'country' => loc == 'XX' ? nil : loc }
end

def exit_curl_args(port, url)
  ['--http1.1', '--proxy', "http://127.0.0.1:#{port}", '--noproxy', '', '--connect-timeout', '4', '--max-time', '6', url]
end

def probe_sleep(seconds)
  sleep(seconds)
end

def verify_exit_ip(port, expected_country = 'US', sleeper: method(:probe_sleep), &runner)
  probe = runner || lambda do |format, url|
    args = exit_curl_args(port, url)
    format == :trace ? curl_trace(args, label: '出口 IP 查询') : curl_json(args, label: '出口 IP 查询')
  end
  last_error = nil
  EXIT_PROBES.each_with_index do |(format, url), index|
    sleeper.call(0.3) if index > 0
    begin
      return verify_country(probe.call(format, url), expected_country)
    rescue CheckFailed => error
      raise unless error.kind == 'transient'
      last_error = error
    end
  end
  raise last_error
end

def verify_anthropic_delay(api, node, sleeper: method(:probe_sleep))
  query = URI.encode_www_form('url' => 'https://api.anthropic.com/', 'timeout' => '6000')
  encoded_node = URI.encode_www_form_component(node).gsub('+', '%20')
  2.times do |attempt|
    sleeper.call(0.4) if attempt > 0
    begin
      health = api.call('/proxies/' + encoded_node + '/delay?' + query, 8)
      raise CheckFailed.new("锁定节点“#{node}”无法通过 Anthropic 连通性检测，请检查节点。", kind: 'transient', code: 'anthropic_unreachable') unless health['delay'].to_i > 0
      return health
    rescue CheckFailed => error
      raise if attempt == 1 || error.kind != 'transient'
    end
  end
end

def check_proxy(quick: false)
  verified = nil
  settings = load_settings
  root = File.expand_path('~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev')
  base = read_yaml(File.join(root, 'config.yaml'))
  runtime = read_yaml(File.join(root, 'clash-verge.yaml'))
  socket = runtime['external-controller-unix'] || base['external-controller-unix']
  raise CheckFailed, 'Clash Verge 或代理内核尚未运行，请先打开 Clash Verge。' unless socket.is_a?(String) && File.socket?(socket)
  secret = runtime['secret'] || base['secret']
  headers = secret.to_s.empty? ? '' : "header = #{JSON.generate('Authorization: Bearer ' + secret.to_s)}\n"
  api = lambda do |path, timeout = 4|
    label = path.include?('/delay?') ? 'Anthropic 连通性检测' : '本机 Clash 检测'
    curl_json(['--noproxy', '*', '--unix-socket', socket, '--connect-timeout', '2', '--max-time', timeout.to_s, '--config', '-', 'http://localhost' + path], headers, label: label, kind: path.include?('/delay?') ? 'transient' : 'configuration')
  end
  text, _error, status = Open3.capture3('/usr/sbin/scutil', '--proxy')
  raise CheckFailed, '无法读取系统代理状态，请手动确认 Clash Verge。' unless status.success?
  system_proxy = text.lines.each_with_object({}) do |line, result|
    match = line.match(/^\s*(\w+)\s*:\s*(.*?)\s*$/)
    result[match[1]] = match[2] if match
  end
  state = api.call('/configs')
  verify_state(system_proxy, state, api.call('/rules').fetch('rules'), api.call('/proxies').fetch('proxies'), group: settings[:group], node: settings[:node])
  verify_connections(api.call('/connections')['connections'], group: settings[:group], node: settings[:node])
  verified = verify_exit_ip(state.fetch('mixed-port').to_i, settings[:country]) unless quick
  verify_anthropic_delay(api, settings[:node])
  return { ok: true, message: '系统代理、Claude 分流、活跃连接和 Anthropic 连通性检查通过。', expectedCountry: settings[:country] } if quick
  label = settings[:country] == 'US' ? '美国出口' : "#{settings[:country]} 出口"
  { ok: true, message: "#{label}已核验，代理连通正常。运行中将持续监测。" }.merge(verified)
rescue CheckFailed => error
  if verified
    raise CheckFailed.new(error.message, ip: verified[:ip], country: verified[:country], kind: error.kind, code: error.code)
  end
  raise
end

def self_test
  group = 'Claude专用'
  node = '供应商-HTTP'
  raise 'Successful response did not parse' unless parse_curl_result("{\"ok\":true}\n200", 0, '测试') == { 'ok' => true }
  [["\n429", 22, 'http_429'], ["\n000", 28, 'timeout'], ["not JSON\n200", 0, 'invalid_json']].each do |output, exit_code, expected|
    begin
      parse_curl_result(output, exit_code, '测试')
      raise 'A failed probe was accepted'
    rescue CheckFailed => error
      raise 'Probe failure classification changed' unless error.kind == 'transient' && error.code == expected
    end
  end
  begin
    parse_curl_result("\n503", 22, '本机 Clash 检测', 'configuration')
  rescue CheckFailed => error
    raise 'Local routing errors must remain distinct from country mismatches' unless error.kind == 'configuration'
  end
  system_proxy = %w[HTTP HTTPS].each_with_object({}) do |kind, result|
    result.merge!(kind + 'Enable' => '1', kind + 'Proxy' => '127.0.0.1', kind + 'Port' => '7897')
  end
  state = { 'mixed-port' => 7897, 'mode' => 'rule' }
  rules = DOMAINS.map { |domain| { 'type' => 'DomainSuffix', 'payload' => domain, 'proxy' => group } } + [{ 'type' => 'Match', 'proxy' => 'DIRECT' }]
  proxies = { group => { 'now' => node } }
  verify_state(system_proxy, state, rules, proxies, group: group, node: node)
  verified = verify_country({ 'ip' => '192.0.2.10', 'country' => 'US' }, 'US')
  raise 'Exit IP was lost' unless verified == { ip: '192.0.2.10', country: 'US', expectedCountry: 'US' }
  defaults = load_settings('/nonexistent/claude-proxy-guard.json', {})
  raise 'Unexpected default settings' unless defaults == { group: 'Claude专用', node: '供应商-HTTP', country: 'US' }
  overridden = load_settings('/nonexistent/claude-proxy-guard.json', { 'CLAUDE_GUARD_GROUP' => 'AI', 'CLAUDE_GUARD_NODE' => 'US-01', 'CLAUDE_GUARD_COUNTRY' => 'sg' })
  raise 'Env override failed' unless overridden == { group: 'AI', node: 'US-01', country: 'SG' }
  failures = [
    -> { verify_state(system_proxy.merge('HTTPEnable' => '0'), state, rules, proxies, group: group, node: node) },
    -> { verify_state(system_proxy.merge('HTTPSPort' => '8888'), state, rules, proxies, group: group, node: node) },
    -> { verify_state(system_proxy, state.merge('mode' => 'direct'), rules, proxies, group: group, node: node) },
    -> { verify_state(system_proxy, state, rules.drop(1), proxies, group: group, node: node) },
    -> { verify_state(system_proxy, state, [{ 'type' => 'Match', 'proxy' => 'DIRECT' }] + rules, proxies, group: group, node: node) },
    -> { verify_state(system_proxy, state, rules, { group => { 'now' => 'DIRECT' } }, group: group, node: node) },
    -> { verify_country({ 'ip' => '192.0.2.20', 'country' => 'CN' }, 'US') },
    -> { verify_country({ 'ip' => '192.0.2.20' }, 'US') },
    -> { verify_country({ 'ip' => 'invalid', 'country' => 'US' }, 'US') },
    -> { verify_country({}, 'US') },
    -> { load_settings('/nonexistent/claude-proxy-guard.json', { 'CLAUDE_GUARD_COUNTRY' => 'USA' }) }
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
    verify_country({ 'ip' => '192.0.2.20', 'country' => 'CN' }, 'US')
  rescue CheckFailed => error
    raise 'Non-US exit IP was lost' unless error.ip == '192.0.2.20' && error.country == 'CN'
    raise 'Non-US failure must stop immediately' unless error.kind == 'country' && error.code == 'country_mismatch'
  end
  begin
    verify_country('ip' => '192.0.2.20')
  rescue CheckFailed => error
    raise 'Unknown country should be retried' unless error.kind == 'transient' && error.code == 'country_unknown'
  end
  raise 'Exit curl args must force HTTP/1.1' unless exit_curl_args(7897, 'https://ipinfo.io/json').include?('--http1.1')
  raise 'Trace response did not parse' unless parse_trace_result("fl=1\nip=192.0.2.15\nloc=US\n\n200", 0) == { 'ip' => '192.0.2.15', 'country' => 'US' }
  raise 'Trace XX country must map to nil' unless parse_trace_result("ip=192.0.2.15\nloc=XX\n\n200", 0) == { 'ip' => '192.0.2.15', 'country' => nil }
  calls = []
  retried_ip = verify_exit_ip(7897, 'US', sleeper: ->(_) {}) do |fmt, url|
    calls << [fmt, url]
    raise CheckFailed.new('出口 IP 查询超时，暂时无法确认检测结果。', kind: 'transient', code: 'timeout') if calls.length == 1
    { 'ip' => '192.0.2.11', 'country' => 'US' }
  end
  raise 'Primary ipinfo transient failure did not retry' unless calls.map(&:last) == ['https://ipinfo.io/json', 'https://ipinfo.io/json'] && retried_ip == { ip: '192.0.2.11', country: 'US', expectedCountry: 'US' }
  fallback_calls = []
  fallback_ip = verify_exit_ip(7897, 'US', sleeper: ->(_) {}) do |fmt, url|
    fallback_calls << [fmt, url]
    raise CheckFailed.new('出口 IP 查询超时，暂时无法确认检测结果。', kind: 'transient', code: 'timeout') if url.include?('ipinfo.io')
    { 'ip' => '192.0.2.12', 'country' => 'US' }
  end
  raise 'Fallback trace source was not used after ipinfo retries failed' unless fallback_calls.last == [:trace, 'https://claude.ai/cdn-cgi/trace'] && fallback_ip == { ip: '192.0.2.12', country: 'US', expectedCountry: 'US' }
  non_us_calls = 0
  begin
    verify_exit_ip(7897, 'US', sleeper: ->(_) {}) do |_fmt, _url|
      non_us_calls += 1
      { 'ip' => '192.0.2.20', 'country' => 'CN' }
    end
    raise 'Non-US exit was accepted'
  rescue CheckFailed => error
    raise 'Non-US exit must stop immediately without fallback' unless non_us_calls == 1 && error.kind == 'country' && error.code == 'country_mismatch'
  end
  delay_calls = 0
  verify_anthropic_delay(lambda { |_path, _timeout = 8|
    delay_calls += 1
    raise CheckFailed.new('Anthropic 连通性检测未成功（http_504），暂时无法确认检测结果。', kind: 'transient', code: 'http_504') if delay_calls == 1
    { 'delay' => 240 }
  }, node, sleeper: ->(_) {})
  raise 'Anthropic delay transient failure did not retry once' unless delay_calls == 2
  verify_connections(nil, group: group, node: node)
  verify_connections([
    { 'metadata' => { 'host' => 'notclaude.ai' }, 'chains' => ['DIRECT'] },
    { 'metadata' => { 'host' => 'api.anthropic.com.' }, 'chains' => [node, group] },
    { 'metadata' => { 'host' => '', 'sniffHost' => 'claude.ai' }, 'chains' => [node, 'ISP自动容错', group] }
  ], group: group, node: node)
  [
    [{ 'metadata' => { 'host' => 'claude.ai' }, 'chains' => ['DIRECT'] }],
    [{ 'metadata' => { 'host' => '', 'sniffHost' => 'api.anthropic.com' }, 'chains' => ['DIRECT'] }],
    [{ 'metadata' => { 'host' => 'claude.com' }, 'chains' => ['其他节点', group] }],
    [{ 'metadata' => { 'host' => 'anthropic.com' }, 'chains' => [node, 'GLOBAL'] }]
  ].each do |bad_conns|
    begin
      verify_connections(bad_conns, group: group, node: node)
      raise 'Route leak was not rejected'
    rescue CheckFailed => error
      raise 'Route leak must be classified as leak' unless error.kind == 'leak' && error.code == 'route_leak'
    end
  end
  { ok: true, message: "自检通过：正常状态及 #{failures.length} 种异常状态均符合预期，出口 IP 会保留供面板显示。" }
end

if $PROGRAM_NAME == __FILE__
  expected = 'US'
  begin
    expected = load_settings[:country] unless ARGV.include?('--self-test')
    result = ARGV.include?('--self-test') ? self_test : check_proxy(quick: ARGV.include?('--quick'))
  rescue CheckFailed => error
    result = { ok: false, message: error.message, ip: error.ip, country: error.country, expectedCountry: expected, kind: error.kind, code: error.code }
  rescue StandardError
    result = { ok: false, message: '检测未能完成，暂时无法确认代理出口。请手动检查 Clash Verge。', expectedCountry: expected, kind: 'configuration', code: 'checker_error' }
  end
  puts JSON.generate(result)
end
