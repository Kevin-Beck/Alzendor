namespace AlzendorCore.Utilities.Actions
{
    class MessageAction : Action
    {
        public string Sender { get; set; }
        public string Reciever { get; set; }
        public string Message { get; set; }
        public MessageType Type { get; set; }
        public MessageAction(string sender, string reciever, MessageType type, string message) : base("Message", ActionPriority.LOW, ActionType.MESSAGE)
        {
            Sender = sender;
            Reciever = reciever;
            Type = type;
            Message = message;
        }
    }
}
