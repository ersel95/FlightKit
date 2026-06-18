cask "flightkit" do
  version "1.0.12"
  sha256 "16db5604975b5d1f88deeb7c21559d7eb76848875a4ac535725dfa17e436f8f3"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
