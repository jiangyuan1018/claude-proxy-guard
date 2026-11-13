require 'tmpdir'
require 'socket'
require File.expand_path(ARGV.fetch(0, '../Resources/proxy_check.rb'), __dir__)

# Exercise the real checker with local fixtures; no network or user configuration is read.
def load_settings(*)
  { group: 'Claude专用', node: '供应商-HTTP', country: 'US' }
end

def read_yaml(*)
  { 'external-controller-unix' => $probe_socket, 'mixed-port' => 7897 }
end

def Open3.capture3(*arguments, **)
  raise 'Unexpected external command' unless arguments == ['/usr/sbin/scutil', '--proxy']
  text = %w[HTTP HTTPS].map { |kind| "#{kind}Enable : 1\n#{kind}Proxy : 127.0.0.1\n#{kind}Port : 7897\n" }.join
  [text, '', Class.new { def success?; true; end }.new]
end

def probe_sleep(_seconds); end

def curl_json(arguments, _config = '', **)
  url = arguments.last
  return { 'mode' => 'rule', 'mixed-port' => 7897 } if url.end_with?('/configs')
  return { 'rules' => DOMAINS.map { |d| { 'type' => 'DomainSuffix', 'payload' => d, 'proxy' => 'Claude专用' } } } if url.end_with?('/rules')
  return { 'proxies' => { 'Claude专用' => { 'now' => '供应商-HTTP' } } } if url.end_with?('/proxies')
  return { 'connections' => $probe_connections || [] } if url.end_with?('/connections')
  if url.include?('ipinfo.io')
    $probe_calls << :ip
    raise CheckFailed.new('IP lookup timeout', kind: 'transient', code: 'timeout') if $probe_ip_timeout
    return { 'ip' => '192.0.2.10', 'country' => $probe_country }
  end
  if url.include?('/delay?')
    $probe_calls << :health
    raise CheckFailed.new('Health timeout', kind: 'transient', code: 'http_504') if $probe_health_timeout
    return { 'delay' => 200 }
  end
  raise 'Unexpected request'
end

def curl_trace(_arguments, **)
  $probe_calls << :trace
  raise CheckFailed.new('Trace lookup timeout', kind: 'transient', code: 'timeout') if $probe_trace_timeout
  { 'ip' => '192.0.2.10', 'country' => $probe_country }
end

def expect_failure(kind, code, ip: nil, quick: false)
  begin
    check_proxy(quick: quick)
    raise 'A failed check was accepted'
  rescue CheckFailed => error
    raise 'Failure kind changed' unless error.kind == kind
    raise 'Failure code changed' unless Array(code).include?(error.code)
    raise 'Verified IP was lost or invented' unless error.ip == ip
  end
end

Dir.mktmpdir('cg-probes-', '/tmp') do |directory|
  $probe_socket = File.join(directory, 'controller.sock')
  server = UNIXServer.new($probe_socket)
  begin
    $probe_connections = []
    $probe_calls = []; $probe_country = 'US'; $probe_health_timeout = true; $probe_ip_timeout = false; $probe_trace_timeout = false
    expect_failure('transient', 'http_504', ip: '192.0.2.10')
    raise 'Health failure hid the exit lookup or skipped retry' unless $probe_calls == [:ip, :health, :health]

    $probe_calls = []; $probe_country = 'CN'
    expect_failure('country', %w[country_not_us country_mismatch], ip: '192.0.2.10')
    raise 'Health failure masked a non-US exit' unless $probe_calls == [:ip]

    $probe_calls = []; $probe_country = 'US'
    expect_failure('transient', 'http_504', quick: true)
    raise 'Quick check unexpectedly queried the IP' unless $probe_calls == [:health, :health]

    $probe_calls = []; $probe_health_timeout = false
    result = check_proxy
    raise 'A healthy US exit was rejected' unless result[:ok] && result[:country] == 'US'
    raise 'Full check order changed' unless $probe_calls == [:ip, :health]

    $probe_calls = []; $probe_ip_timeout = true; $probe_trace_timeout = false
    fallback_result = check_proxy
    raise 'Trace fallback did not recover US exit' unless fallback_result[:ok] && fallback_result[:country] == 'US'
    raise 'Trace fallback sequence changed' unless $probe_calls == [:ip, :ip, :trace, :health]

    $probe_calls = []; $probe_ip_timeout = true; $probe_trace_timeout = true
    expect_failure('transient', 'timeout')
    raise 'Unknown exit was treated as a confirmed country' unless $probe_calls == [:ip, :ip, :trace, :trace]

    $probe_calls = []; $probe_ip_timeout = false; $probe_trace_timeout = false
    $probe_connections = [{ 'metadata' => { 'host' => 'claude.ai' }, 'chains' => ['DIRECT'] }]
    expect_failure('leak', 'route_leak')
    raise 'Live route leak did not stop before external probes' unless $probe_calls.empty?
  ensure
    server.close
  end
end
puts '出口独立核验回归通过：测速失败保留美国 IP，非美国出口优先阻断，未知出口不伪造国家。'
