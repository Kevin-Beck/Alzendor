namespace Alzendor.Core.Utilities.Actions
{
    public class MessageAction : UserAction
    {
        public string Sender { get; set; }
        public string receiver { get; set; }
        public string Message { get; set; }
        public MessageType MessageType { get; set; }
        public MessageAction(string sender, string receiver, MessageType type, string message) : base("Message", ActionPriority.LOW, ActionType.MESSAGE)
        {
            Sender = sender;
            receiver = receiver;
            MessageType = type;
            Message = message;
        }
    }
}
