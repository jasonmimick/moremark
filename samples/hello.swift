// press Cmd+Shift+H to see these bytes raw
import Foundation

let family = ["cat", "more", "less", "moremark"]
for (i, cmd) in family.enumerated() {
    print(String(repeating: " ", count: i * 2) + cmd)
}
