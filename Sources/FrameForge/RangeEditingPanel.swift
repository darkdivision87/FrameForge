import SwiftUI

/// A proportional timeline for scrubbing and selecting a section to ripple-delete.
struct RangeEditingPanel: View {
    @EnvironmentObject var store: Store
    private var duration: Double { max(0.001,store.project.duration) }
    private func position(_ time: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(1,max(0,time/duration))) * width
    }
    private func time(_ x: CGFloat, width: CGFloat) -> Double {
        min(duration,max(0,Double(x/max(1,width))*duration))
    }
    private func handle(_ value: Double, isIn: Bool, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius:3).fill(Color.orange).frame(width:10,height:36)
            .overlay(Text(isIn ? "I" : "O").font(.caption2.bold()).foregroundColor(.black))
            .position(x:min(width-5,max(5,position(value,width:width))),y:20)
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("rangeTimeline")).onChanged { event in
                let value = time(event.location.x,width:width)
                if isIn { store.rangeIn = min(value,store.rangeOut ?? duration) }
                else { store.rangeOut = max(value,store.rangeIn ?? 0) }
                store.seek(value)
            })
            .accessibilityLabel(isIn ? "Drag In point" : "Drag Out point")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment:.leading) {
                    RoundedRectangle(cornerRadius:5).fill(Color.blue.opacity(0.25))
                    if let lower = store.rangeIn, let upper = store.rangeOut, upper > lower {
                        Rectangle().fill(Color.red.opacity(0.35))
                            .frame(width:position(upper-lower,width:width),height:30)
                            .offset(x:position(lower,width:width))
                    }
                    Rectangle().fill(Color.white).frame(width:2,height:30)
                        .offset(x:min(width-2,position(store.playhead,width:width)))
                }.frame(height:30).padding(.vertical,5).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { event in
                        store.player.pause(); store.seek(time(event.location.x,width:width))
                    })
                if let lower = store.rangeIn { handle(lower,isIn:true,width:width) }
                if let upper = store.rangeOut { handle(upper,isIn:false,width:width) }
            }.frame(height:40).coordinateSpace(name:"rangeTimeline")
            HStack(spacing:8) {
                Button("Mark In",action:store.markIn).keyboardShortcut("i",modifiers:.option).help("Mark range start at playhead (⌥I)")
                Button("Mark Out",action:store.markOut).keyboardShortcut("o",modifiers:.option).help("Mark range end at playhead (⌥O)")
                Button("Remove Range",action:store.removeRange).keyboardShortcut("x",modifiers:[.command,.shift])
                    .tint(.red).disabled(!store.canRemoveRange)
                Button(action:store.clearRange) { Image(systemName:"xmark.circle") }.help("Clear range")
            }.controlSize(.small)
            HStack(spacing:6) {
                Text("In")
                TextField("seconds",value:$store.rangeIn,format:.number.precision(.fractionLength(2))).frame(width:65)
                Text("Out")
                TextField("seconds",value:$store.rangeOut,format:.number.precision(.fractionLength(2))).frame(width:65)
                if store.canRemoveRange, let lower = store.rangeIn, let upper = store.rangeOut {
                    Text("Remove \(timeLabel(upper-lower))").foregroundColor(.orange)
                }
                Spacer(minLength:0)
            }.textFieldStyle(.roundedBorder).font(.caption)
        }.disabled(store.project.clips.isEmpty || store.busy || store.recording)
    }
}
