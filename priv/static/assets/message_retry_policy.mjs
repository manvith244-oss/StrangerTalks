export function messageSendTimeoutDisposition({socketConnected, channelState}) {
  return socketConnected === true && channelState === "joined" ? "failed" : "reconcile"
}