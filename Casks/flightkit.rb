cask "flightkit" do
  version "1.0.0"
  sha256 "878ca5384be606403a14fcb23651b267065ccaf2df3144d20437dc03d6893d28"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
