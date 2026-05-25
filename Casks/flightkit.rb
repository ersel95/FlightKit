cask "flightkit" do
  version "1.0.2"
  sha256 "abc6ad60c4191eafee64d51f7e66f7c4364e02175478f8fb2e79760a9c1f43fd"

  url "https://github.com/ersel95/FlightKit/releases/download/v#{version}/FlightKit-#{version}.dmg"
  name "FlightKit"
  desc "Menu-driven TestFlight & App Store publisher for iOS apps"
  homepage "https://github.com/ersel95/FlightKit"

  app "FlightKit.app"

  zap trash: [
    "~/Library/Application Support/FlightKit",
  ]
end
