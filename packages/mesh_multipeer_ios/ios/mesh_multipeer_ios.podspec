Pod::Spec.new do |s|
  s.name             = 'mesh_multipeer_ios'
  s.version          = '0.1.0'
  s.summary          = 'Multipeer Connectivity transport for the offline mesh messenger.'
  s.description      = 'Moves raw packets between nearby iOS devices. No protocol logic.'
  s.homepage         = 'https://example.invalid/offline-mesh'
  s.license          = { :type => 'MIT' }
  s.author           = { 'offline-mesh' => 'dev@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'MultipeerConnectivity', 'CoreBluetooth'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
