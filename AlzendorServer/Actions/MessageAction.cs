using AlzendorServer.Elements;
namespace AlzendorServer.Actions
{
    public class MessageAction : ActionObject
    {
        public string Message { get; set; }

        public MessageAction(string sender, string receiver, string message) : base(sender, ActionType.MESSAGE, ElementType.CHANNEL, receiver, ActionPriority.LOW)
        {
            Message = message;
        }
    }
}
