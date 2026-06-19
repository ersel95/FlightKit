cask "flightkit" do
  version "1.0.15"
  sha256 "af77ea65195d9a5d65f0d9f86f064654ed7a3d9645712502932c65fb51eca5a4"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
