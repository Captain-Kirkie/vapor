import NIOCore
import NIOConcurrencyHelpers

extension Request {
    final class BodyStream: BodyStreamWriter {
        let eventLoop: EventLoop

        var isBeingRead: Bool {
            self.handlerBuffer.value.handler != nil
        }
        
        /// **WARNING** This should only be used when we know we're on an event loop
        ///
        struct HandlerBufferContainer: @unchecked Sendable {
            var handler: ((BodyStreamResult, EventLoopPromise<Void>?) -> ())?
            var buffer: [(BodyStreamResult, EventLoopPromise<Void>?)]
        }

        private let isClosed: NIOLoopBoundBox<Bool>
        private let handlerBuffer: NIOLoopBoundBox<HandlerBufferContainer>
        private let allocator: ByteBufferAllocator

        init(on eventLoop: EventLoop, byteBufferAllocator: ByteBufferAllocator) {
            self.eventLoop = eventLoop
            self.isClosed = .init(false, eventLoop: eventLoop)
            self.handlerBuffer = .init(.init(handler: nil, buffer: []), eventLoop: eventLoop)
            self.allocator = byteBufferAllocator
        }
        
        /// `read(_:)` **must** be called when on an `EventLoop`
        func read(_ handler: @escaping (BodyStreamResult, EventLoopPromise<Void>?) -> ()) {
            self.eventLoop.preconditionInEventLoop()
            self.handlerBuffer.value.handler = handler
            for (result, promise) in self.handlerBuffer.value.buffer {
                handler(result, promise)
            }
            self.handlerBuffer.value.buffer = []
        }

        func write(_ chunk: BodyStreamResult, promise: EventLoopPromise<Void>?) {
            // See https://github.com/vapor/vapor/issues/2906
            if self.eventLoop.inEventLoop {
                write0(chunk, promise: promise)
            } else {
                self.eventLoop.execute {
                    self.write0(chunk, promise: promise)
                }
            }
        }
        
        private func write0(_ chunk: BodyStreamResult, promise: EventLoopPromise<Void>?) {
            switch chunk {
            case .end, .error:
                self.isClosed.value = true
            case .buffer: break
            }
            
            if let handler = self.handlerBuffer.value.handler {
                handler(chunk, promise)
                // remove reference to handler
                switch chunk {
                case .end, .error:
                    self.handlerBuffer.value.handler = nil
                default: break
                }
            } else {
                self.handlerBuffer.value.buffer.append((chunk, promise))
            }
        }

        func consume(max: Int?, on eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
            // See https://github.com/vapor/vapor/issues/2906
            return eventLoop.flatSubmit {
                let promise = eventLoop.makePromise(of: ByteBuffer.self)
                var data = self.allocator.buffer(capacity: 0)
                self.read { chunk, next in
                    switch chunk {
                    case .buffer(var buffer):
                        if let max = max, data.readableBytes + buffer.readableBytes >= max {
                            promise.fail(Abort(.payloadTooLarge))
                        } else {
                            data.writeBuffer(&buffer)
                        }
                    case .error(let error): promise.fail(error)
                    case .end: promise.succeed(data)
                    }
                    next?.succeed(())
                }
                
                return promise.futureResult
            }
        }

        deinit {
            assert(self.isClosed.value, "Request.BodyStream deinitialized before closing.")
        }
    }
}
