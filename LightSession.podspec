# A CocoaPods spec alongside the Swift package, not instead of it.
#
# SwiftPM is how an iOS app should take this, and it is what the README documents. This exists because React
# Native's iOS build is CocoaPods: the `lightsession-react-native` package is a pod, and a pod can only depend
# on another pod. Without this file the bridge would have to vendor a copy of these sources, and a second copy
# of an SDK is a second thing to keep in step — which it never is.
#
# The two must not drift, so both read whole directories rather than listing files: the same trees the package's
# targets name. Adding a file needs no edit in either.
Pod::Spec.new do |s|
  s.name             = 'LightSession'
  # Igual a tag mais recente, e tem de continuar igual: `s.source` abaixo resolve a fonte por
  # `:tag => s.version`, entao um numero desatualizado aqui nao falha — entrega silenciosamente o
  # codigo de outra release. Estava em 0.1.0 com as tags em 0.2.x, ou seja cinco releases atras.
  s.version          = '0.2.5'
  s.summary          = 'Session recording and screen mapping for iOS.'
  s.description      = <<~DESC
    Maps an app's screens as wireframes and screenshots, records taps and swipes for a touch heatmap, and
    records session replay frames. Native Swift, no dependencies. Text is covered before a capture leaves the
    device.
  DESC
  s.homepage         = 'https://github.com/lightsession/lightsession-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = 'LightSession'
  s.source           = { :git => 'https://github.com/lightsession/lightsession-ios.git', :tag => s.version.to_s }

  # 15 for the same reason the Swift package says so: finding the key window through `UIWindowScene` needs it,
  # and a second code path for that would rot because only one branch is ever exercised.
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  # Both source trees, one module.
  #
  # The Objective-C file is one function wrapping `-[CALayer presentationLayer]` in `@try/@catch`,
  # because Swift cannot catch an Objective-C exception and that call can raise. The Swift package
  # keeps it in a target of its own — SwiftPM allows one language per target — while a pod is a
  # single mixed-language module, so the header comes in through the generated umbrella and
  # `UIViewSnapshot` reaches the function without importing anything. The `module.modulemap` beside
  # the header is not matched here on purpose: CocoaPods writes its own, and two would disagree.
  s.source_files     = 'Sources/LightSession/**/*.swift', 'Sources/LightSessionSafe/**/*.{h,m}'
  s.frameworks       = 'UIKit', 'WebKit'
end
