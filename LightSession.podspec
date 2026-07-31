# A CocoaPods spec alongside the Swift package, not instead of it.
#
# SwiftPM is how an iOS app should take this, and it is what the README documents. This exists because React
# Native's iOS build is CocoaPods: the `lightsession-react-native` package is a pod, and a pod can only depend
# on another pod. Without this file the bridge would have to vendor a copy of these sources, and a second copy
# of an SDK is a second thing to keep in step — which it never is.
#
# The two must not drift, so there is exactly one source list and both read it: `Sources/LightSession/**/*.swift`
# here, and the same directory as the package's target there. Adding a file needs no edit in either.
Pod::Spec.new do |s|
  s.name             = 'LightSession'
  s.version          = '0.1.0'
  s.summary          = 'Session recording and screen mapping for iOS.'
  s.description      = <<~DESC
    Maps an app's screens as wireframes and screenshots, records taps and swipes for a touch heatmap, and
    records session replay frames. Native Swift, no dependencies. Text is covered before a capture leaves the
    device.
  DESC
  s.homepage         = 'https://github.com/lightsession/lightsession-ios'
  s.license          = { :type => 'UNLICENSED' }
  s.author           = 'LightSession'
  s.source           = { :git => 'https://github.com/lightsession/lightsession-ios.git', :tag => s.version.to_s }

  # 15 for the same reason the Swift package says so: finding the key window through `UIWindowScene` needs it,
  # and a second code path for that would rot because only one branch is ever exercised.
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  s.source_files     = 'Sources/LightSession/**/*.swift'
  s.frameworks       = 'UIKit', 'WebKit'
end
