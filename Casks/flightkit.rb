cask "flightkit" do
  version "1.0.8"
  sha256 "1a40ab1b751bb7602b88766f517aa6dadddb6728f4be7bc9a9c0c653a7159e67"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
