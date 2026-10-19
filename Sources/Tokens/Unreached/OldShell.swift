


//
import AVFoundation
import AppKit
import Combine
import Speech
import SwiftUI


// ProductShell


struct ProductShell: View {
    @ObservedObject var model: TalkModel
    @State private var betaPreview: BetaPreviewProduct?
    var body: some View {
        HStack(spacing: 0) {
            Group {
                if !["Telescope", "Tincture"].contains(model.selectedProduct) {
                    ScrollView { StyleChooser(model: model).id(model.selectedProduct) }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            if publicTokens && model.selectedProduct == "Tokens" {
                                HStack(alignment: .center, spacing: 3) {
                                    Text("π").font(.system(size: 27, design: .serif))
                                    Text(appName).font(.system(size: 25, design: .serif))
                                }
                            } else {
                                ProductWordmark(product: model.selectedProduct, size: 25)
                            }
                            Spacer()
                            if model.selectedProduct != "Tincture" {
                                Button { model.toggleProductDrawer() } label: { Image(systemName: "line.3.horizontal") }
                                    .buttonStyle(.plain).accessibilityLabel("Switch products")
                                    .onHover { model.hoverProductDrawer($0) }
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AcademicGraphPaper())
                }
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if model.productDrawerExpanded {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(["Tokens", "Talk", "Telescope", "Tincture"], id: \.self) { product in
                        Button {
                            if publicTokens && product != "Tokens" {
                                betaPreview = BetaPreviewProduct(name: product)
                            } else {
                                model.chooseProduct(product)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if model.selectedProduct == "Tincture" { Text("π “Open \(product)”").font(.system(size: 18, design: .serif)) }
                                    else { ProductWordmark(product: product, size: 18) }
                                    if product != "Tokens" {
                                        Image(systemName: "lock").font(.system(size: 10, weight: .regular))
                                    }
                                }
                                Text(product == "Tokens" ? "Free" : "Private beta")
                                    .font(.system(size: 11, design: .serif)).foregroundStyle(.secondary)
                            }.foregroundStyle(model.selectedProduct == product ? academicRed : academicInk)
                        }.buttonStyle(.plain).disabled(!model.productSwitchAllowed)
                    }
                    if !model.productSwitchAllowed {
                        Text("Finish dictation to switch products.").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20).frame(width: 180, alignment: .leading)
                    .frame(maxHeight: .infinity).background(AcademicGraphPaper())
                .onHover { model.hoverProductDrawer($0) }
            }
        }.preferredColorScheme(.light)
        .onChange(of: model.selectedProduct) { _, product in model.setInputPreviewVisible(!["Telescope", "Tincture"].contains(product)) }
        .sheet(item: $betaPreview) { preview in
            BetaPreviewSheet(product: preview.name)
        }
    }
}

//
// :)
//
//
// BetaPreviewProduct


struct BetaPreviewProduct: Identifiable {
    let name: String
    var id: String { name }
}


// BetaPreviewSheet


struct BetaPreviewSheet: View {
    let product: String
    @Environment(\.dismiss) private var dismiss

    private var description: String {
        switch product {
        case "Talk":      return "A private dictation workspace for a more personal, continuous conversation."
        case "Telescope": return "A native camera and hand-gesture workspace for navigating ideas in space."
        default:          return "A tiny local-model workspace for training, testing, and comparing experiments."
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: product == "Telescope" ? "scope" : product == "Talk" ? "bubble.left.and.bubble.right" : "flask")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(academicRed)
            ProductWordmark(product: product, size: 28)
            Text("Private beta")
                .font(.system(size: 11, weight: .medium, design: .serif))
                .foregroundStyle(academicPencil)
            Text("Coming soon")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(academicInk)
            Text(description)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(academicPencil)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(academicRed)
        }
        .padding(34)
        .frame(width: 380, height: 300)
        .background(AcademicGraphPaper())
        .preferredColorScheme(.light)
    }
}

