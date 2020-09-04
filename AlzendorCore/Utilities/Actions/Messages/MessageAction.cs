namespace AlzendorCore.Utilities.Actions
{
    public class MessageAction : UserAction
    {
        public string Sender { get; set; }
        public string Reciever { get; set; }
        public string Message { get; set; }
        public MessageType MessageType { get; set; }
        public MessageAction(string sender, string reciever, MessageType type, string message) : base("Message", ActionPriority.LOW, ActionType.MESSAGE)
        {
            Sender = sender;
            Reciever = reciever;
            MessageType = type;
            Message = message;
        }
    }
}
