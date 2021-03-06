Pod::Spec.new do |s|
  s.name         = "Yakka"
  s.version      = "2.1.2"
  s.summary      = "A toolkit for coordinating the doing of stuff"
  s.homepage     = "https://github.com/KieranHarper/Yakka"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author             = { "Kieran Harper" => "kieranjharper@gmail.com" }
  s.social_media_url   = "https://twitter.com/KieranTheTwit"
  s.ios.deployment_target = "8.0"
  s.osx.deployment_target = "10.10"
  s.watchos.deployment_target = "2.0"
  s.tvos.deployment_target = "9.0"
  s.source       = { :git => "https://github.com/KieranHarper/Yakka.git", :tag => s.version.to_s }
  s.source_files  = "Sources/**/*"
  s.frameworks  = "Foundation"
end
